import 'dart:async';
import 'dart:math';

import 'package:accordsync_core/accordsync_core.dart';

import 'storage.dart';
import 'transport.dart';

/// A local write the server refused. It has already been rolled back on this device.
typedef Refusal = ({OpId opId, String record, String field, String reason});

/// One of the values a conflicted field holds, and the op that wrote it.
typedef ConflictValue = ({Object? value, OpId opId});

/// A `conflict()` field holding more than one value. Equal when the record, field and values are.
final class ConflictInfo {
  const ConflictInfo({required this.record, required this.field, required this.values});

  final String record;
  final String field;

  /// Sorted by op id.
  final List<ConflictValue> values;

  @override
  bool operator ==(Object other) =>
      other is ConflictInfo &&
      other.record == record &&
      other.field == field &&
      canonicalJson(_json(other.values)) == canonicalJson(_json(values));

  @override
  int get hashCode => Object.hash(record, field, canonicalJson(_json(values)));

  @override
  String toString() => 'ConflictInfo($record.$field: $values)';

  static List<Object?> _json(List<ConflictValue> vs) => [
    for (final v in vs) {'value': v.value, 'opId': v.opId},
  ];
}

/// Where sync stands.
typedef SyncStatus = ({int pending, int cursor, int? lastSyncAt, Object? lastError});

/// An Accord device. Writes apply locally at once and are saved to storage; sync pushes them and
/// pulls everyone else's, in the background or on demand. Port of `@accordsync/client`.
final class AccordClient {
  AccordClient._(this._o, this.deviceId, StoredMeta? meta) : _cursor = meta?.cursor ?? 0 {
    _writer = _newWriter(meta == null ? null : (hlc: Hlc.decode(meta.hlc), seq: meta.seq));
  }

  /// Opens the device: loads its stored ops, outbox and cursor.
  ///
  /// [deviceId] is used only the first time; afterwards the stored id is kept. Generated when
  /// absent. [pushBatch] is the ops per push request and [pullLimit] the items per pull page.
  /// Background sync pauses [syncInterval] between successful rounds and backs off between
  /// [minBackoff] and [maxBackoff] on errors.
  static Future<AccordClient> open({
    required Schema schema,
    required StorageAdapter storage,
    required Transport transport,
    String? deviceId,
    int Function()? now,
    double Function()? random,
    int pushBatch = 200,
    int pullLimit = 500,
    Duration syncInterval = const Duration(seconds: 30),
    Duration minBackoff = const Duration(seconds: 1),
    Duration maxBackoff = const Duration(seconds: 60),
  }) async {
    final o = _Options(
      schema: schema,
      storage: storage,
      transport: transport,
      now: now ?? () => DateTime.now().millisecondsSinceEpoch,
      random: random ?? Random().nextDouble,
      pushBatch: pushBatch,
      pullLimit: pullLimit,
      syncInterval: syncInterval,
      minBackoff: minBackoff,
      maxBackoff: maxBackoff,
    );
    final snap = await storage.load();
    final id = snap.meta?.deviceId ?? deviceId ?? randomDeviceId();
    final client = AccordClient._(o, id, snap.meta);
    for (final base in snap.snapshots) {
      client._writer.replica.loadSnapshot(base);
    }
    final byId = <OpId, Op>{};
    for (final raw in snap.ops) {
      final op = decodeOp(raw);
      byId[op.opId] = op;
      client._writer.receive(op);
    }
    for (final id in [...snap.outbox]..sort(_bySeq)) {
      final op = byId[id];
      if (op != null) client._outbox[id] = op;
    }
    if (snap.meta == null) await client._persist(const StorageTx());
    return client;
  }

  final String deviceId;
  final _Options _o;
  late LocalWriter _writer;

  /// Unacknowledged local ops, by id, in write order.
  final Map<OpId, Op> _outbox = {};
  int _cursor;
  Future<void> _chain = Future.value();
  Future<void>? _syncing;
  Timer? _timer;

  /// A write came in during a round: start another soon after it.
  bool _again = false;
  bool _running = false;
  int _failures = 0;
  int? _lastSyncAt;
  Object? _lastError;

  final _changes = StreamController<List<String>>.broadcast(sync: true);
  final _refusals = StreamController<Refusal>.broadcast(sync: true);
  final _synced = StreamController<int>.broadcast(sync: true);
  final _resyncs = StreamController<void>.broadcast(sync: true);
  final _errors = StreamController<Object>.broadcast(sync: true);

  /// Records whose local state changed (a local write, ops received, a rollback, a scope exit).
  Stream<List<String>> get changes => _changes.stream;

  /// Local writes the server refused, already rolled back.
  Stream<Refusal> get refusals => _refusals.stream;

  /// A sync round finished (everything pushed, everything available pulled), with the cursor.
  Stream<int> get synced => _synced.stream;

  /// The server asked for a resync (read scopes changed); local data was reloaded.
  Stream<void> get resyncs => _resyncs.stream;

  /// A sync round failed; background sync will retry with backoff.
  Stream<Object> get errors => _errors.stream;

  // ── reading ────────────────────────────────────────────────────────────

  /// A record's fields, or `null` if this device has never seen it. Fields with no value are left
  /// out.
  Map<String, Object?>? read(String record) => _writer.replica.read(record);

  List<String> records([String? type]) {
    final all = _writer.replica.records();
    return type == null ? all : all.where((r) => r.startsWith('$type:')).toList();
  }

  /// Every `conflict()` field holding more than one value, with the values.
  List<ConflictInfo> conflicts() => [
    for (final (:record, :field) in _writer.replica.conflicts())
      ConflictInfo(
        record: record,
        field: field,
        values: [
          for (final v
              in ((read(record)![field]! as Map<String, Object?>)['conflicted']! as List<Object?>)
                  .cast<Map<String, Object?>>())
            (value: v['value'], opId: v['opId']! as String),
        ],
      ),
  ];

  SyncStatus status() =>
      (pending: _outbox.length, cursor: _cursor, lastSyncAt: _lastSyncAt, lastError: _lastError);

  // ── writing (local-first) ──────────────────────────────────────────────

  /// Sets a `lww` or `conflict` field. Completes once the write is saved on this device.
  Future<AssignOp> assign(String record, String field, Object? value) =>
      _write(_writer.assign(record, field, value));

  /// Resolves a conflicted field: writes [value], superseding every value currently shown.
  Future<AssignOp> resolve(String record, String field, Object? value) =>
      assign(record, field, value);

  Future<IncOp> inc(String record, String field, int by) => _write(_writer.inc(record, field, by));

  Future<AddOp> add(String record, String field, Object element) =>
      _write(_writer.add(record, field, element));

  Future<RemoveOp> remove(String record, String field, Object element) =>
      _write(_writer.remove(record, field, element));

  Future<T> _write<T extends Op>(T op) async {
    _outbox[op.opId] = op;
    _changes.add([op.record]);
    await _persist(StorageTx(putOps: [encodeOp(op)], outboxAdd: [op.opId]));
    _soon();
    return op;
  }

  // ── sync ───────────────────────────────────────────────────────────────

  /// One full round: push the outbox, then pull every page. Concurrent calls share the round.
  Future<void> sync() => _syncing ??= _round().whenComplete(() {
    _syncing = null;
    // A write during the round is not in it: sync again soon, not after the interval.
    if (_again) {
      _again = false;
      _schedule(const Duration(milliseconds: 50));
    }
  });

  /// Syncs in the background: after each write, every `syncInterval`, and with backoff on errors.
  void start() {
    if (_running) return;
    _running = true;
    _schedule(Duration.zero);
  }

  void stop() {
    _running = false;
    _timer?.cancel();
  }

  /// Waits for pending local saves.
  Future<void> flush() => _chain;

  Future<void> close() async {
    stop();
    await _syncing?.catchError((_) {});
    await flush();
    await _o.storage.close();
    for (final c in [_changes, _refusals, _synced, _resyncs, _errors]) {
      await c.close();
    }
  }

  Future<void> _round() async {
    await _pushAll();
    for (;;) {
      final page = await _o.transport.pull(deviceId, _cursor, _o.pullLimit);
      switch (page) {
        case ResyncRequired():
          await _pushAll();
          await _resync();
          continue;
        case PullPage():
          // The server's count of this device's ops: never reuse an op id, even after lost storage.
          if (page.deviceSeq != null) _writer.advanceSeq(page.deviceSeq!);
          await _applyPage(page.items, page.cursor);
          if (!page.hasMore) break;
          continue;
      }
      break;
    }
    _lastSyncAt = _o.now();
    _lastError = null;
    _failures = 0;
    _synced.add(_cursor);
  }

  Future<void> _pushAll() async {
    while (_outbox.isNotEmpty) {
      final batch = _outbox.values.take(_o.pushBatch).toList();
      final res = await _o.transport.push(deviceId, batch.map(encodeOp).toList());
      if (res.acked.isEmpty && res.refused.isEmpty) {
        throw StateError('server neither acknowledged nor refused a non-empty push');
      }
      res.acked.forEach(_outbox.remove);
      final refusals = <Refusal>[];
      for (final r in res.refused) {
        final op = _outbox.remove(r.opId);
        if (op != null) {
          refusals.add((opId: op.opId, record: op.record, field: op.field, reason: r.reason));
        }
      }
      if (refusals.isNotEmpty) _writer.discard(refusals.map((r) => r.opId));
      await _persist(
        StorageTx(
          outboxDelete: [...res.acked, ...res.refused.map((r) => r.opId)],
          deleteOps: [for (final r in refusals) r.opId],
        ),
      );
      if (refusals.isNotEmpty) _changes.add({for (final r in refusals) r.record}.toList());
      refusals.forEach(_refusals.add);
    }
  }

  Future<void> _applyPage(List<PullItem> items, int cursor) async {
    final put = <OpId, Op>{};
    final forgotten = <OpId>[];
    final snapshots = <RecordSnapshot>[];
    final dropSnapshots = <String>[];
    final changed = <String>{};
    final pending = _outbox.keys.toSet();
    List<OpId> notPending(String record) => [
      for (final o in _writer.replica.ops())
        if (o.record == record && !pending.contains(o.opId)) o.opId,
    ];
    for (final item in items) {
      switch (item) {
        case OpItem(:final op):
          final decoded = decodeOp(op);
          if (_writer.receive(decoded) == ApplyResult.applied) {
            put[decoded.opId] = decoded;
            changed.add(decoded.record);
          }
        case SnapshotItem(:final snapshot):
          // A compacted record: its snapshot replaces the ops it folded; our unpushed edits stay on
          // top. The server sends a snapshot before any later op of that record.
          for (final id in notPending(snapshot.record)) {
            put.remove(id);
            forgotten.add(id);
          }
          _writer.replica.loadSnapshot(snapshot, pending);
          snapshots.add(snapshot);
          changed.add(snapshot.record);
        case ExitItem(:final record):
          // The record left our scope: forget it, except our own unpushed edits, which will be
          // pushed, refused and rolled back like any other refused write.
          final ids = notPending(record);
          ids.forEach(put.remove);
          _writer.forget(record, pending);
          forgotten.addAll(ids);
          dropSnapshots.add(record);
          changed.add(record);
      }
    }
    _cursor = max(_cursor, cursor);
    final snapshotted = {for (final s in snapshots) s.record};
    await _persist(
      StorageTx(
        deleteOps: forgotten,
        deleteSnapshots: [
          for (final r in dropSnapshots)
            if (!snapshotted.contains(r)) r,
        ],
        putSnapshots: [
          for (final s in snapshots)
            if (!dropSnapshots.contains(s.record)) s,
        ],
        putOps: [for (final op in put.values) encodeOp(op)],
      ),
    );
    if (changed.isNotEmpty) _changes.add(changed.toList());
  }

  /// Read scopes changed: keep only unpushed local ops and pull everything again from zero.
  Future<void> _resync() async {
    final keep = _outbox.values.toList();
    final before = _writer.replica.records();
    _writer = _newWriter((hlc: _writer.clock, seq: _writer.seq));
    for (final op in keep) {
      _writer.receive(op);
    }
    _cursor = 0;
    await _persist(StorageTx(clearOps: true, putOps: [for (final op in keep) encodeOp(op)]));
    _resyncs.add(null);
    _changes.add(before);
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    if (!_running) return;
    late final Timer timer;
    timer = Timer(delay, () {
      sync().then(
        // Unless a write rescheduled sooner meanwhile.
        (_) {
          if (identical(_timer, timer)) _schedule(_o.syncInterval);
        },
        onError: (Object error) {
          _failures++;
          _lastError = error;
          _errors.add(error);
          final base = min(
            _o.maxBackoff.inMicroseconds,
            _o.minBackoff.inMicroseconds * pow(2, _failures - 1),
          );
          // Jitter: phones don't retry in lockstep.
          _schedule(Duration(microseconds: (base * (0.5 + _o.random() / 2)).round()));
        },
      );
    });
    _timer = timer;
  }

  /// After a write, sync shortly (writes in a burst share one round).
  void _soon() {
    if (!_running || _failures != 0) return;
    if (_syncing != null) {
      _again = true;
    } else {
      _schedule(const Duration(milliseconds: 50));
    }
  }

  LocalWriter _newWriter(({Hlc hlc, int seq})? resume) => LocalWriter(
    schema: _o.schema,
    deviceId: deviceId,
    now: _o.now,
    // The server already refused ops with absurd clocks; a device with a wrong clock of its own
    // must still accept everything the server sends.
    maxSkewMs: maxSafeInteger,
    resume: resume,
  );

  Future<void> _persist(StorageTx tx) {
    final meta = StoredMeta(
      deviceId: deviceId,
      cursor: _cursor,
      hlc: _writer.clock.encode(),
      seq: _writer.seq,
    );
    final run = _chain.then((_) => _o.storage.commit(tx.withMeta(meta)));
    _chain = run.catchError((_) {});
    return run;
  }
}

final class _Options {
  const _Options({
    required this.schema,
    required this.storage,
    required this.transport,
    required this.now,
    required this.random,
    required this.pushBatch,
    required this.pullLimit,
    required this.syncInterval,
    required this.minBackoff,
    required this.maxBackoff,
  });
  final Schema schema;
  final StorageAdapter storage;
  final Transport transport;
  final int Function() now;
  final double Function() random;
  final int pushBatch;
  final int pullLimit;
  final Duration syncInterval;
  final Duration minBackoff;
  final Duration maxBackoff;
}

int _bySeq(OpId a, OpId b) => parseOpId(a).seq.compareTo(parseOpId(b).seq);

/// A random device id from a secure source (`Random.secure`). Device ids must never collide, and
/// are never derived from the hardware.
String randomDeviceId([Random? random]) {
  final r = random ?? Random.secure();
  return 'd${List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
}
