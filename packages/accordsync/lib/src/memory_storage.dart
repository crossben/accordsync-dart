import 'dart:convert';

import 'package:accordsync_core/accordsync_core.dart';

import 'storage.dart';

/// In-memory storage: for tests, and for apps that accept losing unsynced writes on restart.
final class MemoryStorage extends StorageAdapter {
  final Map<OpId, Map<String, Object?>> _ops = {};
  final Map<String, RecordSnapshot> _snapshots = {};
  final Set<OpId> _outbox = {};
  StoredMeta? _meta;

  @override
  Future<StorageSnapshot> load() async => StorageSnapshot(
    meta: _meta,
    snapshots: [for (final s in _snapshots.values) _copySnapshot(s)],
    ops: [for (final o in _ops.values) _copy(o)],
    outbox: [..._outbox],
  );

  @override
  Future<void> commit(StorageTx tx) async {
    if (tx.clearOps) {
      _ops.clear();
      _snapshots.clear();
    }
    tx.deleteSnapshots.forEach(_snapshots.remove);
    for (final s in tx.putSnapshots) {
      _snapshots[s.record] = _copySnapshot(s);
    }
    tx.deleteOps.forEach(_ops.remove);
    for (final o in tx.putOps) {
      _ops[o['op_id']! as String] = _copy(o);
    }
    _outbox
      ..addAll(tx.outboxAdd)
      ..removeAll(tx.outboxDelete);
    if (tx.meta != null) _meta = tx.meta;
  }
}

Map<String, Object?> _copy(Map<String, Object?> o) =>
    jsonDecode(jsonEncode(o)) as Map<String, Object?>;

RecordSnapshot _copySnapshot(RecordSnapshot s) => RecordSnapshot.fromJson(_copy(s.toJson()));
