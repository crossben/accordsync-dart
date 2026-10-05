/// The storage adapter contract (port of `storage.test.ts`). Every [StorageAdapter] must pass it:
/// call [storageContract] from a test file with a factory for fresh stores.
library;

import 'package:accordsync/accordsync.dart';
import 'package:test/test.dart';

Map<String, Object?> _op(int n) => {
  'op_id': 'd:$n',
  'record': 'dossier:1',
  'field': 'visits',
  'kind': 'inc',
  'by': n,
  'hlc': '${1000 + n}:00000:d',
};

StoredMeta _meta(int cursor) =>
    StoredMeta(deviceId: 'd', cursor: cursor, hlc: '1000:00000:d', seq: 3);

RecordSnapshot _snap(int n) => RecordSnapshot('dossier:1', {
  'visits': {'strategy': 'counter', 'total': n},
});

/// Runs the contract on stores from [make]; [reopen], when given, opens the same data again.
void storageContract(
  String name,
  ({StorageAdapter store, StorageAdapter Function()? reopen}) Function() make,
) {
  group('$name storage', () {
    test('starts empty', () async {
      final s = await make().store.load();
      expect(s.meta, isNull);
      expect(s.snapshots, isEmpty);
      expect(s.ops, isEmpty);
      expect(s.outbox, isEmpty);
    });

    test('commits ops, outbox and meta, and applies deletes, clears and outbox removals', () async {
      final store = make().store;
      await store.commit(
        StorageTx(putOps: [_op(1), _op(2), _op(3)], outboxAdd: ['d:1', 'd:2'], meta: _meta(5)),
      );
      await store.commit(StorageTx(deleteOps: ['d:3'], outboxDelete: ['d:1'], meta: _meta(7)));
      final s = await store.load();
      expect(s.ops.map((o) => o['op_id']).toList()..sort(), ['d:1', 'd:2']);
      expect(s.outbox, ['d:2']);
      expect(s.meta, _meta(7));

      await store.commit(StorageTx(clearOps: true, putOps: [_op(9)]));
      expect((await store.load()).ops, [_op(9)]);
    });

    test('stores snapshots, replaced by record, cleared with the ops', () async {
      final store = make().store;
      await store.commit(StorageTx(putSnapshots: [_snap(1)]));
      await store.commit(StorageTx(putSnapshots: [_snap(2)]));
      expect([for (final s in (await store.load()).snapshots) s.toJson()], [_snap(2).toJson()]);
      await store.commit(const StorageTx(deleteSnapshots: ['dossier:1']));
      expect((await store.load()).snapshots, isEmpty);
      await store.commit(StorageTx(putSnapshots: [_snap(3)], putOps: [_op(1)]));
      await store.commit(const StorageTx(clearOps: true));
      final s = await store.load();
      expect(s.snapshots, isEmpty);
      expect(s.ops, isEmpty);
    });

    test('returns copies, not live references', () async {
      final store = make().store;
      final o = _op(1);
      await store.commit(StorageTx(putOps: [o]));
      o['by'] = 99;
      final loaded = (await store.load()).ops.single;
      expect(loaded, _op(1));
      loaded['by'] = 98;
      expect((await store.load()).ops.single, _op(1));
    });

    if (make().reopen != null) {
      test('survives a restart', () async {
        final (:store, :reopen) = make();
        await store.commit(StorageTx(putOps: [_op(1)], outboxAdd: ['d:1'], meta: _meta(2)));
        await store.close();
        final again = await reopen!().load();
        expect(again.meta, _meta(2));
        expect(again.ops, [_op(1)]);
        expect(again.outbox, ['d:1']);
      });
    }
  });
}
