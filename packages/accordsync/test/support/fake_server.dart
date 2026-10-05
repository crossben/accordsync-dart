import 'dart:convert';

import 'package:accordsync/accordsync.dart';

/// Read and write scope keys of a user.
typedef Access = ({List<String> read, List<String> write});

/// An in-memory Accord server, enough to exercise every client path without PostgreSQL. It follows
/// the protocol rules a client depends on (docs/protocol.md): pushes applied in order and
/// idempotent, refusals (out of scope, op id already used, schema), `device_seq`, paged pulls with
/// `has_more`, exits when a record leaves the reader's scope and its whole history when it enters,
/// snapshots after compaction, and resync on demand. The real server is checked in F3.
final class FakeServer {
  FakeServer({required this.schema, required this.scopes, required this.access});

  final Schema schema;

  /// A record's scope keys, from its current fields.
  final List<String> Function(String record, Map<String, Object?> fields) scopes;

  /// A user's keys. Read on every request, like JWT claims.
  Access Function(String user) access;

  late Replica _state = Replica(schema);

  /// The feed: ops and snapshots, in the order the server took them. Position = index + 1.
  /// A folded op leaves an empty slot, so stored cursors keep their meaning.
  final List<Object?> _feed = []; // Map<String, Object?> wire op | RecordSnapshot | null
  final Map<OpId, String> _applied = {}; // op id → canonical wire JSON
  final Map<String, String> _deviceUser = {};
  final Map<String, int> _deviceSeq = {};

  /// Records each device holds, as far as the server knows (to send entries and exits).
  final Map<String, Set<String>> _sent = {};
  final Set<String> _resync = {};

  /// Fails the next n requests, as a dropped connection would.
  int failNext = 0;

  int requests = 0;

  /// A transport for [user]'s devices.
  Transport transportFor(String user) => _FakeTransport(this, user);

  /// The next pull of [deviceId] answers `resync_required`.
  void requireResync(String deviceId) => _resync.add(deviceId);

  /// Folds a record's history into a snapshot (ADR-0008): its ops leave the feed, and a snapshot
  /// entry is appended.
  void compact(String record) {
    for (var i = 0; i < _feed.length; i++) {
      if (_recordOf(_feed[i]) == record) _feed[i] = null;
    }
    _feed.add(_state.snapshotRecord(record));
  }

  void _check(String user, String deviceId) {
    requests++;
    if (failNext > 0) {
      failNext--;
      throw const HttpError(503, 'network down');
    }
    final owner = _deviceUser.putIfAbsent(deviceId, () => user);
    if (owner != user) throw HttpError(403, 'device $deviceId belongs to another user');
  }

  bool _overlap(List<String> a, List<String> b) => a.any(b.contains);

  List<String> _keys(Replica r, String record) {
    final fields = r.read(record);
    return fields == null ? const [] : scopes(record, fields);
  }

  PushResult push(String user, String deviceId, List<Map<String, Object?>> ops) {
    _check(user, deviceId);
    final acked = <OpId>[];
    final refused = <({OpId opId, String reason})>[];
    for (final raw in ops) {
      final id = raw['op_id']! as String;
      final canonical = canonicalJson(raw);
      final seen = _applied[id];
      if (seen != null) {
        seen == canonical ? acked.add(id) : refused.add((opId: id, reason: 'op id already used'));
        continue;
      }
      final Op op;
      try {
        op = decodeOp(raw);
        if (parseOpId(id).device != deviceId) throw AccordException('belongs to another device');
        _state.validate(op);
      } on AccordException catch (e) {
        refused.add((opId: id, reason: e.message));
        continue;
      }
      final write = access(user).write;
      final existing = _state.read(op.record) != null;
      final after = _state.without(const {})..apply(op);
      final keys = existing ? _keys(_state, op.record) : _keys(after, op.record);
      if (!_overlap(keys, write)) {
        refused.add((opId: id, reason: 'out of scope: you may not write ${op.record}'));
        continue;
      }
      _state = after;
      _applied[id] = canonical;
      _feed.add(jsonDecode(jsonEncode(raw)) as Map<String, Object?>);
      final seq = parseOpId(id).seq;
      if (seq > (_deviceSeq[deviceId] ?? 0)) _deviceSeq[deviceId] = seq;
      acked.add(id);
    }
    return PushResult(acked: acked, refused: refused);
  }

  PullResult pull(String user, String deviceId, int cursor, int limit) {
    _check(user, deviceId);
    if (_resync.remove(deviceId)) {
      _sent[deviceId] = {};
      return const ResyncRequired();
    }
    if (cursor == 0) _sent[deviceId] = {};
    final sent = _sent.putIfAbsent(deviceId, () => {});
    final read = access(user).read;
    bool visible(String record) => _overlap(_keys(_state, record), read);

    final items = <PullItem>[];
    // Scope changes since the last pull: exits, then the whole history of records that entered.
    for (final r in [...sent]) {
      if (!visible(r)) {
        sent.remove(r);
        items.add(ExitItem(r));
      }
    }
    for (final r in _state.records()) {
      if (visible(r) && !sent.contains(r) && _recordBefore(r, cursor)) {
        sent.add(r);
        items.addAll(_history(r, cursor));
      }
    }
    var pos = cursor;
    while (pos < _feed.length && items.length < limit) {
      final e = _feed[pos++];
      final record = _recordOf(e);
      if (record == null || !visible(record)) continue;
      sent.add(record);
      items.add(e is RecordSnapshot ? SnapshotItem(e) : OpItem(e as Map<String, Object?>));
    }
    return PullPage(
      items: items,
      cursor: pos,
      hasMore: pos < _feed.length,
      deviceSeq: _deviceSeq[deviceId],
    );
  }

  /// Whether the record has feed entries this device already skipped (it entered the scope late).
  bool _recordBefore(String record, int cursor) =>
      _feed.take(cursor).any((e) => _recordOf(e) == record);

  String? _recordOf(Object? e) => switch (e) {
    final RecordSnapshot s => s.record,
    final Map<String, Object?> m => m['record']! as String,
    _ => null,
  };

  Iterable<PullItem> _history(String record, int cursor) sync* {
    for (final e in _feed.take(cursor)) {
      if (e is RecordSnapshot && e.record == record) yield SnapshotItem(e);
      if (e is Map<String, Object?> && e['record'] == record) yield OpItem(e);
    }
  }
}

final class _FakeTransport implements Transport {
  _FakeTransport(this.server, this.user);
  final FakeServer server;
  final String user;

  // Through JSON both ways, like the network, and asynchronous.
  @override
  Future<PushResult> push(String deviceId, List<Map<String, Object?>> ops) async {
    await Future<void>.delayed(Duration.zero);
    final wire = (jsonDecode(jsonEncode(ops)) as List<Object?>).cast<Map<String, Object?>>();
    return server.push(user, deviceId, wire);
  }

  @override
  Future<PullResult> pull(String deviceId, int cursor, int limit) async {
    await Future<void>.delayed(Duration.zero);
    return server.pull(user, deviceId, cursor, limit);
  }
}
