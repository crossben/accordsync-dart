import 'package:accordsync_core/accordsync_core.dart';

/// What a device must remember between launches.
final class StoredMeta {
  const StoredMeta({
    required this.deviceId,
    required this.cursor,
    required this.hlc,
    required this.seq,
  });

  factory StoredMeta.fromJson(Map<String, Object?> json) => StoredMeta(
    deviceId: json['deviceId']! as String,
    cursor: (json['cursor']! as num).toInt(),
    hlc: json['hlc']! as String,
    seq: (json['seq']! as num).toInt(),
  );

  final String deviceId;

  /// Pull cursor: server feed position already applied.
  final int cursor;

  /// Last clock (encoded) and op sequence number, so op ids are never reused after a restart.
  final String hlc;
  final int seq;

  Map<String, Object?> toJson() => {'deviceId': deviceId, 'cursor': cursor, 'hlc': hlc, 'seq': seq};

  @override
  bool operator ==(Object other) =>
      other is StoredMeta &&
      other.deviceId == deviceId &&
      other.cursor == cursor &&
      other.hlc == hlc &&
      other.seq == seq;

  @override
  int get hashCode => Object.hash(deviceId, cursor, hlc, seq);

  @override
  String toString() => 'StoredMeta${toJson()}';
}

/// Everything a device has stored.
final class StorageSnapshot {
  const StorageSnapshot({
    this.meta,
    this.snapshots = const [],
    this.ops = const [],
    this.outbox = const [],
  });

  final StoredMeta? meta;

  /// Compacted records: their state with older ops folded away (ADR-0008). Loaded before ops.
  final List<RecordSnapshot> snapshots;

  /// Every op the device holds (its own and received), in the wire format.
  final List<Map<String, Object?>> ops;

  /// Ids of local ops not yet acknowledged by the server.
  final List<OpId> outbox;
}

/// One atomic change. Applied in this order: clear, delete, put, outbox changes, meta.
final class StorageTx {
  const StorageTx({
    this.clearOps = false,
    this.deleteSnapshots = const [],
    this.putSnapshots = const [],
    this.deleteOps = const [],
    this.putOps = const [],
    this.outboxAdd = const [],
    this.outboxDelete = const [],
    this.meta,
  });

  /// Removes every op and snapshot.
  final bool clearOps;
  final List<String> deleteSnapshots;
  final List<RecordSnapshot> putSnapshots;
  final List<OpId> deleteOps;
  final List<Map<String, Object?>> putOps;
  final List<OpId> outboxAdd;
  final List<OpId> outboxDelete;
  final StoredMeta? meta;

  StorageTx withMeta(StoredMeta meta) => StorageTx(
    clearOps: clearOps,
    deleteSnapshots: deleteSnapshots,
    putSnapshots: putSnapshots,
    deleteOps: deleteOps,
    putOps: putOps,
    outboxAdd: outboxAdd,
    outboxDelete: outboxDelete,
    meta: meta,
  );
}

/// Durable storage for a device. [commit] must be atomic: after a crash, either all of a
/// transaction is visible or none of it.
abstract class StorageAdapter {
  Future<StorageSnapshot> load();
  Future<void> commit(StorageTx tx);
  Future<void> close() async {}
}
