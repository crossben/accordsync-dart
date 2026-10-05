import 'package:accordsync/accordsync.dart';
import 'package:test/test.dart';

import 'support.dart';

/// The Dart client over real HTTP against the real server: the scenarios of the TypeScript e2e
/// suite whose outcome depends on the server (refusal reasons, exits, scope deltas, compaction,
/// device_seq).
void main() {
  final tokens = <String, String>{};

  setUpAll(requireServer);
  setUp(() async {
    await resetServer();
    tokens['awa'] = await tokenFor('awa', ['dakar']);
    tokens['moussa'] = await tokenFor('moussa', ['dakar']);
    tokens['fatou'] = await tokenFor('fatou', ['thies']);
  });

  Future<AccordClient> open(String user, String deviceId, {StorageAdapter? storage}) =>
      AccordClient.open(
        schema: schema,
        storage: storage ?? MemoryStorage(),
        deviceId: deviceId,
        transport: HttpTransport(url: serverUrl, getToken: () => tokens[user]!),
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
    await syncAll([awa, moussa]);
    await awa.inc('dossier:1', 'visits', 2);
    await awa.add('dossier:1', 'docs', 'cni.pdf');
    await moussa.inc('dossier:1', 'visits', 3);
    await moussa.assign('dossier:1', 'client_name', 'Aminata Fall');
    await moussa.assign('dossier:1', 'status', 'rejected');
    await awa.assign('dossier:1', 'status', 'approved');
    await syncAll([awa, moussa]);
    for (final c in [awa, moussa]) {
      expect(c.read('dossier:1'), {
        'agent': 'awa',
        'zone': 'dakar',
        'client_name': 'Aminata Fall',
        'status': {
          'conflicted': [
            {'value': 'approved', 'opId': 'awa-phone:5'},
            {'value': 'rejected', 'opId': 'moussa-phone:3'},
          ],
        },
        'visits': 5,
        'docs': ['cni.pdf'],
      });
      expect(c.status().pending, 0);
    }
    await moussa.resolve('dossier:1', 'status', 'approved');
    await syncAll([awa, moussa]);
    expect(awa.conflicts(), isEmpty);
    expect(snapshotOf(awa), snapshotOf(moussa));
  });

  test('a refused write is rolled back locally and reported with the server reason', () async {
    final fatou = await open('fatou', 'fatou-phone');
    final awa = await open('awa', 'awa-phone');
    await fatou.assign('dossier:7', 'zone', 'thies');
    await fatou.sync();
    final refusals = <Refusal>[];
    awa.refusals.listen(refusals.add);
    await awa.assign('dossier:7', 'client_name', 'not mine');
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
  });

  test('a record reassigned away leaves the device and reaches the new agent', () async {
    final awa = await open('awa', 'awa-phone');
    final fatou = await open('fatou', 'fatou-phone');
    await awa.assign('dossier:3', 'agent', 'awa');
    await awa.inc('dossier:3', 'visits', 4);
    await awa.sync();
    await awa.assign('dossier:3', 'agent', 'fatou');
    await awa.sync();
    expect(awa.read('dossier:3'), isNull);
    await fatou.sync();
    expect(fatou.read('dossier:3'), {'agent': 'fatou', 'visits': 4, 'docs': <Object?>[]});
  });

  test('follows a change of read scopes as a delta', () async {
    final fatou = await open('fatou', 'fatou-phone');
    await fatou.assign('dossier:8', 'zone', 'thies');
    await fatou.sync();
    final awa = await open('awa', 'awa-phone');
    await awa.assign('dossier:1', 'zone', 'dakar');
    await awa.sync();
    tokens['awa'] = await tokenFor('awa', ['dakar', 'thies']);
    await awa.inc('dossier:8', 'visits', 1);
    var resyncs = 0;
    awa.resyncs.listen((_) => resyncs++);
    await awa.sync();
    expect(resyncs, 0);
    expect(awa.records(), ['dossier:1', 'dossier:8']);
    expect(awa.read('dossier:8'), {'zone': 'thies', 'visits': 1, 'docs': <Object?>[]});
  });

  test('after compaction, a new device gets the snapshot and merges on top', () async {
    final awa = await open('awa', 'awa-phone');
    await awa.assign('dossier:1', 'zone', 'dakar');
    for (var i = 0; i < 4; i++) {
      await awa.inc('dossier:1', 'visits', 1);
    }
    await awa.add('dossier:1', 'docs', 'a.pdf');
    await awa.remove('dossier:1', 'docs', 'a.pdf');
    await awa.assign('dossier:1', 'status', 'submitted');
    await syncAll([awa]);
    expect((await compactServer())['records'], 1);

    final storage = MemoryStorage();
    final tablet = await open('awa', 'awa-tablet', storage: storage);
    await tablet.inc('dossier:1', 'visits', 10);
    await tablet.sync();
    expect(tablet.read('dossier:1'), {...awa.read('dossier:1')!, 'visits': 14});
    expect((await storage.load()).snapshots.single.record, 'dossier:1');
    await awa.sync();
    expect(snapshotOf(awa), snapshotOf(tablet));
  });

  test('device_seq: a reinstalled device never reuses an op id, even after compaction', () async {
    final before = await open('awa', 'awa-tablet');
    await before.assign('dossier:1', 'zone', 'dakar');
    await before.inc('dossier:1', 'visits', 2);
    await before.sync();
    await before.sync();
    await compactServer();
    final after = await open('awa', 'awa-tablet');
    await after.sync();
    expect((await after.inc('dossier:1', 'visits', 3)).opId, 'awa-tablet:3');
    await after.sync();
    expect(after.status().pending, 0);
    expect(after.read('dossier:1')!['visits'], 5);
  });

  test('a reinstalled device writing before its first sync gets "op id already used"', () async {
    final before = await open('awa', 'awa-old');
    await before.assign('dossier:1', 'zone', 'dakar');
    await before.sync();
    final after = await open('awa', 'awa-old');
    final refusals = <Refusal>[];
    after.refusals.listen(refusals.add);
    await after.inc('dossier:1', 'visits', 1);
    await after.sync();
    expect(refusals.single.reason, contains('op id already used'));
  });

  test('HTTP errors carry the status', () async {
    final c = await AccordClient.open(
      schema: schema,
      storage: MemoryStorage(),
      deviceId: 'nobody',
      transport: HttpTransport(url: serverUrl, getToken: () => 'not-a-jwt'),
    );
    await expectLater(c.sync(), throwsA(isA<HttpError>().having((e) => e.status, 'status', 401)));
  });
}
