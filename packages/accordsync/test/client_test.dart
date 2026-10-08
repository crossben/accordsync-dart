import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:accordsync/accordsync.dart';
import 'package:test/test.dart';

import 'support/fake_server.dart';

/// Port of the client's `e2e.test.ts`, against an in-memory server ([FakeServer]); F3 runs the
/// same scenarios against the real one.
final schema = defineSchema({
  'dossier': {
    'agent': lww(),
    'zone': lww(),
    'client_name': lww(),
    'status': conflict(),
    'visits': counter(),
    'docs': set(),
  },
});

void main() {
  late FakeServer server;
  late Map<String, List<String>> zones;

  setUp(() {
    zones = {
      'awa': ['dakar'],
      'moussa': ['dakar'],
      'fatou': ['thies'],
    };
    server = FakeServer(
      schema: schema,
      scopes: (_, f) => [
        if (f['agent'] is String) 'agent:${f['agent']}',
        if (f['zone'] is String) 'zone:${f['zone']}',
      ],
      access: (user) {
        final keys = ['agent:$user', for (final z in zones[user]!) 'zone:$z'];
        return (read: keys, write: keys);
      },
    );
  });

  Future<AccordClient> open(
    String user,
    String deviceId, {
    StorageAdapter? storage,
    Transport? transport,
    int pullLimit = 500,
    int pushBatch = 200,
  }) => AccordClient.open(
    schema: schema,
    storage: storage ?? MemoryStorage(),
    transport: transport ?? server.transportFor(user),
    deviceId: deviceId,
    pullLimit: pullLimit,
    pushBatch: pushBatch,
  );

  Future<void> syncAll(List<AccordClient> cs) async {
    for (var i = 0; i < 2; i++) {
      for (final c in cs) {
        await c.sync();
      }
    }
  }

  test('two agents edit offline, then converge', () async {
    final awa = await open('awa', 'awa-phone');
    final moussa = await open('moussa', 'moussa-phone');
    await awa.assign('dossier:1', 'zone', 'dakar');
    await awa.assign('dossier:1', 'agent', 'awa');
    await awa.sync();
    await moussa.sync();

    // Both offline: no sync while they work.
    await awa.inc('dossier:1', 'visits', 2);
    await awa.add('dossier:1', 'docs', 'cni.pdf');
    await moussa.inc('dossier:1', 'visits', 3);
    await moussa.assign('dossier:1', 'client_name', 'Aminata Fall');

    await syncAll([awa, moussa]);
    for (final c in [awa, moussa]) {
      expect(c.read('dossier:1'), {
        'agent': 'awa',
        'zone': 'dakar',
        'client_name': 'Aminata Fall',
        'visits': 5,
        'docs': ['cni.pdf'],
      });
      expect(c.status().pending, 0);
    }
  });

  test('surfaces a conflict on both devices, and a resolution clears it everywhere', () async {
    final awa = await open('awa', 'awa-phone');
    final moussa = await open('moussa', 'moussa-phone');
    await awa.assign('dossier:1', 'zone', 'dakar');
    await syncAll([awa, moussa]);

    await awa.assign('dossier:1', 'status', 'approved');
    await moussa.assign('dossier:1', 'status', 'rejected');
    await syncAll([awa, moussa]);
    for (final c in [awa, moussa]) {
      expect(c.conflicts(), [
        const ConflictInfo(
          record: 'dossier:1',
          field: 'status',
          values: [
            (value: 'approved', opId: 'awa-phone:2'),
            (value: 'rejected', opId: 'moussa-phone:1'),
          ],
        ),
      ]);
    }

    await moussa.resolve('dossier:1', 'status', 'approved');
    await syncAll([awa, moussa]);
    for (final c in [awa, moussa]) {
      expect(c.conflicts(), isEmpty);
      expect(c.read('dossier:1')!['status'], {'value': 'approved'});
    }
  });

  test('a refused write is rolled back locally and reported', () async {
    final fatou = await open('fatou', 'fatou-phone');
    final awa = await open('awa', 'awa-phone');
    await fatou.assign('dossier:7', 'zone', 'thies');
    await fatou.sync();

    // Awa cannot see dossier:7, but tries to write to it.
    final refusals = <Refusal>[];
    awa.refusals.listen(refusals.add);
    await awa.assign('dossier:7', 'client_name', 'not mine');
    expect(awa.read('dossier:7')!['client_name'], 'not mine'); // local-first: visible at once
    await awa.sync();
    expect(refusals, [
      (
        opId: 'awa-phone:1',
        record: 'dossier:7',
        field: 'client_name',
        reason: 'out of scope: you may not write dossier:7',
      ),
    ]);
    expect(awa.read('dossier:7'), isNull);
    expect(awa.status().pending, 0);
  });

  test('a record reassigned away is removed from the device', () async {
    final awa = await open('awa', 'awa-phone');
    final fatou = await open('fatou', 'fatou-phone');
    await awa.assign('dossier:3', 'agent', 'awa');
    await awa.inc('dossier:3', 'visits', 4);
    await awa.sync();

    await awa.assign('dossier:3', 'agent', 'fatou');
    final changed = <List<String>>[];
    awa.changes.listen(changed.add);
    await awa.sync();
    expect(awa.read('dossier:3'), isNull);
    expect(changed, anyElement(equals(['dossier:3'])));

    await fatou.sync();
    expect(fatou.read('dossier:3'), containsPair('agent', 'fatou'));
    expect(fatou.read('dossier:3'), containsPair('visits', 4));
  });

  test('follows a change of read scopes without a resync, keeping unpushed edits', () async {
    final fatou = await open('fatou', 'fatou-phone');
    await fatou.assign('dossier:8', 'zone', 'thies');
    await fatou.sync();
    final awa = await open('awa', 'awa-phone');
    await awa.assign('dossier:1', 'zone', 'dakar');
    await awa.sync();
    expect(awa.records(), ['dossier:1']);

    // Awa moves to the Thiès zone too; she keeps working before her next sync.
    zones['awa'] = ['dakar', 'thies'];
    await awa.inc('dossier:8', 'visits', 1);
    var resyncs = 0;
    awa.resyncs.listen((_) => resyncs++);
    await awa.sync();
    expect(resyncs, 0);
    expect(awa.records(), ['dossier:1', 'dossier:8']);
    expect(awa.read('dossier:8'), {'zone': 'thies', 'visits': 1, 'docs': <Object?>[]});
    await fatou.sync();
    expect(fatou.read('dossier:8')!['visits'], 1);
  });

  test('resync_required: unpushed edits are pushed, local data reloaded from zero', () async {
    final awa = await open('awa', 'awa-phone');
    await awa.assign('dossier:1', 'zone', 'dakar');
    await awa.sync();
    await awa.inc('dossier:1', 'visits', 2);
    server.requireResync('awa-phone');
    var resyncs = 0;
    awa.resyncs.listen((_) => resyncs++);
    await awa.sync();
    expect(resyncs, 1);
    expect(awa.status().pending, 0);
    expect(awa.read('dossier:1'), {'zone': 'dakar', 'visits': 2, 'docs': <Object?>[]});
  });

  test('survives a restart: data, outbox, cursor and op numbering are kept', () async {
    final storage = MemoryStorage();
    final first = await open('awa', 'awa-tablet', storage: storage);
    await first.assign('dossier:1', 'zone', 'dakar');
    await first.sync();
    await first.inc('dossier:1', 'visits', 1); // offline, then the app is killed
    final cursorBefore = first.status().cursor;
    expect(cursorBefore, greaterThan(0));
    await first.close();

    final again = await open('awa', 'other-id', storage: storage);
    expect(again.deviceId, 'awa-tablet');
    expect(again.status().pending, 1);
    expect(again.status().cursor, cursorBefore);
    expect(again.read('dossier:1')!['visits'], 1);
    expect((await again.inc('dossier:1', 'visits', 1)).opId, 'awa-tablet:3');
    await again.sync();
    expect(again.status().pending, 0);
  });

  test('writes made during a sync round are not lost', () async {
    final awa = await open('awa', 'awa-phone');
    await awa.assign('dossier:1', 'zone', 'dakar');
    final round = awa.sync();
    await awa.inc('dossier:1', 'visits', 1);
    await round;
    await awa.sync();
    final other = await open('awa', 'awa-laptop');
    await other.sync();
    expect(other.read('dossier:1')!['visits'], 1);
  });

  test('pushes in write order, in batches, and pulls every page', () async {
    final pushed = <OpId>[];
    final pulls = <int>[];
    final awa = await open(
      'awa',
      'awa-phone',
      transport: _Spy(server.transportFor('awa'), pushed, pulls),
      pushBatch: 3,
    );
    await awa.assign('dossier:1', 'zone', 'dakar');
    for (var i = 0; i < 9; i++) {
      await awa.inc('dossier:1', 'visits', 1);
    }
    await awa.sync();
    expect(pushed, [for (var i = 1; i <= 10; i++) 'awa-phone:$i']);

    final reader = await open('moussa', 'moussa-phone', pullLimit: 4);
    await reader.sync();
    expect(reader.read('dossier:1')!['visits'], 9);
    expect(reader.status().cursor, 10);
  });

  for (final seed in [1, 2, 3, 4, 5]) {
    test('random work by three devices converges (seed $seed)', () async {
      final rng = Random(seed);
      final devices = [
        await open('awa', 'awa-1'),
        await open('awa', 'awa-2'),
        await open('moussa', 'moussa-1', pullLimit: 7),
      ];
      await devices[0].assign('dossier:1', 'zone', 'dakar');
      await devices[0].assign('dossier:2', 'zone', 'dakar');
      await syncAll(devices);
      for (var step = 0; step < 80; step++) {
        final d = devices[rng.nextInt(devices.length)];
        final record = 'dossier:${1 + rng.nextInt(2)}';
        switch (rng.nextInt(6)) {
          case 0:
            await d.inc(record, 'visits', rng.nextInt(8) - 2);
          case 1:
            await d.add(record, 'docs', 'doc-${rng.nextInt(4)}');
          case 2:
            await d.remove(record, 'docs', 'doc-${rng.nextInt(4)}');
          case 3:
            await d.assign(record, 'status', 's${rng.nextInt(3)}');
          case 4:
            await d.assign(record, 'client_name', 'n${rng.nextInt(10)}');
          default:
            await d.sync(); // devices sync at random moments, otherwise they are offline
        }
      }
      await syncAll(devices);
      final states = {
        for (final d in devices)
          jsonEncode([
            for (final r in ['dossier:1', 'dossier:2']) d.read(r),
          ]),
      };
      expect(states, hasLength(1));
    });
  }

  test('after compaction, a new device gets the snapshot, keeps it across a restart, and merges '
      'on top', () async {
    final awa = await open('awa', 'awa-phone');
    await awa.assign('dossier:1', 'zone', 'dakar');
    for (var i = 0; i < 4; i++) {
      await awa.inc('dossier:1', 'visits', 1);
    }
    await awa.add('dossier:1', 'docs', 'a.pdf');
    await awa.remove('dossier:1', 'docs', 'a.pdf');
    await awa.assign('dossier:1', 'status', 'submitted');
    await syncAll([awa]);
    server.compact('dossier:1');

    final storage = MemoryStorage();
    final tablet = await open('awa', 'awa-tablet', storage: storage);
    await tablet.inc('dossier:1', 'visits', 10); // a blind offline write to an unseen record
    await tablet.sync();
    expect(tablet.read('dossier:1'), {...awa.read('dossier:1')!, 'visits': 14});
    expect((await storage.load()).snapshots.single.record, 'dossier:1');
    await tablet.close();

    final again = await open('awa', 'x', storage: storage);
    expect(again.read('dossier:1'), {
      'zone': 'dakar',
      'visits': 14,
      'docs': <Object?>[],
      'status': {'value': 'submitted'},
    });
    await awa.sync();
    expect(awa.read('dossier:1')!['visits'], 14);
  });

  test('a device that lost its storage keeps its old ops and never reuses an op id', () async {
    final before = await open('awa', 'awa-tablet');
    await before.assign('dossier:1', 'zone', 'dakar');
    await before.inc('dossier:1', 'visits', 2);
    await before.sync();
    // Reinstalled: empty storage, same device id. Its first sync teaches it its own op numbers.
    final after = await open('awa', 'awa-tablet');
    await after.sync();
    expect((await after.inc('dossier:1', 'visits', 3)).opId, 'awa-tablet:3');
    await after.sync();
    expect(after.status().pending, 0);
    expect(after.read('dossier:1')!['visits'], 5);
  });

  test(
    'device_seq: a reinstalled device whose old ops were compacted never reuses an op id',
    () async {
      final before = await open('awa', 'awa-tablet');
      await before.assign('dossier:1', 'zone', 'dakar');
      await before.inc('dossier:1', 'visits', 2);
      await before.sync();
      server.compact('dossier:1'); // its own ops now arrive folded in a snapshot, not one by one
      final after = await open('awa', 'awa-tablet');
      await after.sync();
      expect((await after.inc('dossier:1', 'visits', 3)).opId, 'awa-tablet:3');
      await after.sync();
      expect(after.status().pending, 0);
      expect(after.read('dossier:1')!['visits'], 5);
    },
  );

  test('a snapshot arriving while a local edit is unpushed keeps the edit on top', () async {
    final awa = await open('awa', 'awa-phone');
    await awa.assign('dossier:1', 'zone', 'dakar');
    await awa.inc('dossier:1', 'visits', 4);
    await awa.sync();
    server.compact('dossier:1');

    late AccordClient tablet;
    final spy = _Spy(server.transportFor('awa'), [], []);
    tablet = await open('awa', 'awa-tablet', transport: spy);
    await tablet.sync();
    server.compact('dossier:1');
    spy.duringPull = () => tablet.inc('dossier:1', 'visits', 1);
    await tablet.sync(); // the snapshot lands while the inc is in the outbox
    expect(tablet.status().pending, 1);
    expect(tablet.read('dossier:1')!['visits'], 5);
    await tablet.sync();
    await awa.sync();
    expect(awa.read('dossier:1')!['visits'], 5);
  });

  test('a reinstalled device that writes before its first sync gets a refusal, never a silent '
      'loss', () async {
    final before = await open('awa', 'awa-old');
    await before.assign('dossier:1', 'zone', 'dakar');
    await before.sync();
    final after = await open('awa', 'awa-old');
    final refusals = <Refusal>[];
    after.refusals.listen(refusals.add);
    await after.inc('dossier:1', 'visits', 1); // offline write, numbered 1 again
    await after.sync();
    expect(refusals.single.reason, contains('op id already used'));
  });

  test('syncs in the background, and backs off while the server is unreachable', () async {
    server.failNext = 2;
    final awa = await AccordClient.open(
      schema: schema,
      storage: MemoryStorage(),
      transport: server.transportFor('awa'),
      deviceId: 'awa-bg',
      minBackoff: const Duration(milliseconds: 10),
      maxBackoff: const Duration(milliseconds: 40),
      syncInterval: const Duration(milliseconds: 20),
    );
    final errors = <Object>[];
    awa.errors.listen(errors.add);
    final synced = awa.synced.first;
    await awa.assign('dossier:1', 'zone', 'dakar');
    awa.start();
    await synced.timeout(const Duration(seconds: 5));
    awa.stop();
    expect(errors, hasLength(greaterThanOrEqualTo(1)));
    expect(errors.first, isA<HttpError>());
    expect(awa.status().pending, 0);
    expect(awa.status().lastError, isNull);
  });

  test(
    'a write during a background round is synced soon after it, not after the interval',
    () async {
      final spy = _Spy(server.transportFor('awa'), [], []);
      final awa = await AccordClient.open(
        schema: schema,
        storage: MemoryStorage(),
        transport: spy,
        deviceId: 'awa-again',
        syncInterval: const Duration(seconds: 60),
      );
      final wrote = Completer<void>();
      spy.duringPull = () async {
        await awa.assign('dossier:1', 'zone', 'dakar');
        wrote.complete();
        // Long enough for the write's 50ms timer to fire while the round is still running.
        await Future<void>.delayed(const Duration(milliseconds: 200));
      };
      awa.start();
      await wrote.future.timeout(const Duration(seconds: 5));
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (awa.status().pending > 0 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(awa.status().pending, 0); // well before syncInterval
      await awa.close();
    },
  );

  test('a failed round leaves the outbox intact, and the next one delivers it', () async {
    final awa = await open('awa', 'awa-phone');
    await awa.assign('dossier:1', 'zone', 'dakar');
    server.failNext = 1;
    await expectLater(awa.sync(), throwsA(isA<HttpError>()));
    expect(awa.status().pending, 1);
    await awa.sync();
    expect(awa.status().pending, 0);
  });
}

final class _Spy implements Transport {
  _Spy(this.inner, this.pushed, this.pulls);
  final Transport inner;
  final List<OpId> pushed;
  final List<int> pulls;

  /// Runs while a pull is in flight (after the round's push): a write made in that window.
  Future<void> Function()? duringPull;

  @override
  Future<PushResult> push(String deviceId, List<Map<String, Object?>> ops) {
    pushed.addAll(ops.map((o) => o['op_id']! as String));
    return inner.push(deviceId, ops);
  }

  @override
  Future<PullResult> pull(String deviceId, int cursor, int limit) async {
    pulls.add(cursor);
    final result = await inner.pull(deviceId, cursor, limit);
    final hook = duringPull;
    duringPull = null;
    if (hook != null) await hook();
    return result;
  }
}
