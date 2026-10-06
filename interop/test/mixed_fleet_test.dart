import 'dart:io';
import 'dart:math';

import 'package:accordsync/accordsync.dart';
import 'package:test/test.dart';

import 'support.dart';

/// The mixed fleet: Dart devices and TypeScript devices work on the same records through the real
/// server over a network that loses requests and responses. After the network heals, every device
/// must hold byte-identical canonical snapshots.
final seeds = [
  for (final s in (Platform.environment['ACCORD_INTEROP_SEEDS'] ?? '1,2,3').split(','))
    int.parse(s),
];

void main() {
  setUpAll(requireServer);

  for (final seed in seeds) {
    test('Dart and TypeScript devices converge (seed $seed)', () async {
      await resetServer();
      final rng = Random(seed);
      final awa = await tokenFor('awa', ['dakar']);
      final moussa = await tokenFor('moussa', ['dakar']);

      final networks = <FlakyClient>[];
      Future<AccordClient> dart(String id, String token) {
        final net = FlakyClient(Random(seed * 31 + networks.length), 0.25);
        networks.add(net);
        return AccordClient.open(
          schema: schema,
          storage: MemoryStorage(),
          deviceId: id,
          transport: HttpTransport(url: serverUrl, getToken: () => token, client: net),
        );
      }

      final dartDevices = [await dart('dart-awa', awa), await dart('dart-moussa', moussa)];
      final tsDevices = [
        await TsDevice.open(deviceId: 'ts-awa', token: awa, seed: seed * 7 + 1, loss: 0.25),
        await TsDevice.open(deviceId: 'ts-moussa', token: moussa, seed: seed * 7 + 2, loss: 0.25),
      ];
      final records = ['dossier:1', 'dossier:2', 'dossier:é'];

      // Every record starts in the shared zone, written by both kinds of device.
      await dartDevices[0].assign(records[0], 'zone', 'dakar');
      await tsDevices[0].call({
        'cmd': 'assign',
        'record': records[1],
        'field': 'zone',
        'value': 'dakar',
      });
      await dartDevices[1].assign(records[2], 'zone', 'dakar');

      var compactions = 0;
      for (var step = 0; step < 150; step++) {
        final record = records[rng.nextInt(records.length)];
        final (cmd, field, value) = switch (rng.nextInt(7)) {
          0 => ('inc', 'visits', rng.nextInt(9) - 3),
          1 => ('add', 'docs', rng.nextBool() ? 'doc-${rng.nextInt(4)}' : rng.nextInt(3)),
          2 => ('remove', 'docs', rng.nextBool() ? 'doc-${rng.nextInt(4)}' : rng.nextInt(3)),
          3 => ('assign', 'status', ['s0', 's1', null, 2.5, 'é'][rng.nextInt(5)]),
          4 => ('assign', 'client_name', {'n': rng.nextInt(9), '10': true, 'a': 1e21}),
          5 => ('sync', '', null),
          _ => ('sync', '', null),
        };
        final i = rng.nextInt(4);
        if (i < 2) {
          final d = dartDevices[i];
          switch (cmd) {
            case 'inc':
              await d.inc(record, field, value! as int);
            case 'add':
              await d.add(record, field, value!);
            case 'remove':
              await d.remove(record, field, value!);
            case 'assign':
              await d.assign(record, field, value);
            default:
              await d.sync().catchError((Object _) {});
          }
        } else {
          final d = tsDevices[i - 2];
          await d.call(
            cmd == 'sync'
                ? {'cmd': 'sync'}
                : {'cmd': cmd, 'record': record, 'field': field, 'value': value},
          );
        }
        if (step == 75) {
          // Compaction only folds what every live device has pulled, and on a lossy network some
          // device is always behind. Heal, let everyone catch up, compact, then break the network
          // again: later lost-response retries then hit ops that were folded into snapshots.
          for (final n in networks) {
            n.loss = 0;
          }
          for (final d in tsDevices) {
            await d.call({'cmd': 'heal'});
          }
          // Three rounds: the server records the cursor a device sent, one pull behind, and pushes
          // made in round one by later devices move the feed past earlier devices again.
          for (var round = 0; round < 3; round++) {
            for (final d in dartDevices) {
              await d.sync();
            }
            for (final d in tsDevices) {
              await d.call({'cmd': 'sync'});
            }
          }
          compactions = ((await compactServer())['records']! as num).toInt();
          expect(compactions, greaterThan(0), reason: 'the mid-run compaction folded nothing');
          for (final n in networks) {
            n.loss = 0.25;
          }
          for (final d in tsDevices) {
            await d.call({'cmd': 'loss', 'loss': 0.25});
          }
        }
      }

      // Heal the network, then sync everyone until nothing is pending and every device is current.
      for (final n in networks) {
        n.loss = 0;
      }
      for (final d in tsDevices) {
        await d.call({'cmd': 'heal'});
      }
      for (var round = 0; round < 3; round++) {
        for (final d in dartDevices) {
          await d.sync();
        }
        for (final d in tsDevices) {
          expect((await d.call({'cmd': 'sync'}))['ok'], isTrue);
        }
      }

      final snapshots = {
        for (final d in dartDevices) d.deviceId: snapshotOf(d),
        for (final (i, d) in tsDevices.indexed) 'ts-$i': await d.snapshot(),
      };
      expect(snapshots.values.toSet(), hasLength(1), reason: '$snapshots');
      expect(snapshots.values.first, contains('dossier:é'));
      for (final d in dartDevices) {
        expect(d.status().pending, 0);
      }
      printOnFailure('seed $seed: $compactions records compacted mid-run');
      for (final d in tsDevices) {
        await d.close();
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  }
}
