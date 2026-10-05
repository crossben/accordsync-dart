import 'canonical.dart';
import 'errors.dart';
import 'op.dart';
import 'schema.dart';
import 'strategies.dart';

/// A record's state with its history folded away (log compaction, ADR-0008).
final class RecordSnapshot {
  const RecordSnapshot(this.record, this.fields);

  factory RecordSnapshot.fromJson(Map<String, Object?> json) =>
      RecordSnapshot(json['record'] as String, {
        for (final e in (json['fields'] as Map<String, Object?>).entries)
          e.key: e.value as Map<String, Object?>,
      });

  final String record;

  /// field → the field's snapshot JSON (same shape as the TypeScript `FieldSnapshot`).
  final Map<String, Map<String, Object?>> fields;

  Map<String, Object?> toJson() => {'record': record, 'fields': fields};
}

enum ApplyResult { applied, duplicate }

/// An op log and the state projected from it. Pure: no I/O, no clock. Two replicas holding the
/// same set of ops always read the same state, whatever order the ops arrived in. Port of
/// `replica.ts`.
final class Replica {
  Replica(this.schema);

  final Schema schema;
  final Map<OpId, Op> _ops = {};
  final Map<String, Map<String, FieldState>> _records = {};
  final Map<String, RecordSnapshot> _bases = {};

  bool has(OpId opId) => _ops.containsKey(opId);

  int get size => _ops.length;

  /// All ops, in a deterministic order.
  List<Op> ops() => _ops.values.toList()..sort((a, b) => compareOpIds(a.opId, b.opId));

  /// Throws (without changing anything) if the op does not fit the schema.
  void validate(Op op) {
    final strategy = strategyFor(schema, op.record, op.field);
    if (!kinds[strategy]!.contains(op.kind)) {
      throw AccordException(
        'op kind "${op.kind}" does not apply to ${op.field}, a ${strategy.name} field',
      );
    }
    if (parseOpId(op.opId).device != op.hlc.node) {
      throw AccordException('op ${op.opId} carries a clock from "${op.hlc.node}"');
    }
  }

  ApplyResult apply(Op op) {
    if (_ops.containsKey(op.opId)) return ApplyResult.duplicate;
    validate(op);
    applyOp(_state(op.record, op.field), op);
    _ops[op.opId] = op;
    return ApplyResult.applied;
  }

  /// The record's fields, or `null` if no op has touched it. Fields never written are left out.
  Map<String, Object?>? read(String record) {
    final states = _records[record];
    if (states == null) return null;
    final out = <String, Object?>{};
    for (final MapEntry(key: field, value: s) in fieldsOf(schema, record).entries) {
      final v = readState(states[field] ?? emptyState(s));
      if (!identical(v, absent)) out[field] = v;
    }
    return out;
  }

  List<String> records() => _records.keys.toList()..sort();

  /// Every `conflict()` field currently holding more than one value.
  List<({String record, String field})> conflicts() => [
    for (final record in records())
      for (final e in _records[record]!.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))
        if (e.value case final ConflictState s when s.live.length > 1)
          (record: record, field: e.key),
  ];

  /// Op ids a new write to this field must cite (see [AssignOp] and [RemoveOp]).
  List<OpId> observedDeps(String record, String field, [Object? element]) {
    strategyFor(schema, record, field);
    final state = _records[record]?[field];
    return state == null ? [] : fieldObservedDeps(state, element);
  }

  /// The whole state as canonical JSON: equal strings mean converged replicas.
  String snapshot() => canonicalJson({for (final r in records()) r: read(r)});

  /// The record's current state, with its history folded away.
  RecordSnapshot snapshotRecord(String record) => RecordSnapshot(record, {
    for (final e in (_records[record] ?? {}).entries) e.key: snapshotState(e.value),
  });

  /// Replaces a record's state with a snapshot and forgets that record's ops, except [keep] (local
  /// ops not yet on the server), which are applied again on top.
  void loadSnapshot(RecordSnapshot snap, [Set<OpId> keep = const {}]) {
    final reapply = _ops.values
        .where((o) => o.record == snap.record && keep.contains(o.opId))
        .toList();
    _ops.removeWhere((_, op) => op.record == snap.record);
    final fields = <String, FieldState>{};
    for (final e in snap.fields.entries) {
      strategyFor(schema, snap.record, e.key);
      fields[e.key] = stateFromSnapshot(e.value);
    }
    _records[snap.record] = fields;
    _bases[snap.record] = snap;
    for (final op in reapply) {
      apply(op);
    }
  }

  /// A copy without the given ops (same snapshots, every other op): used to roll back.
  Replica without(Set<OpId> drop) {
    final next = Replica(schema);
    for (final snap in _bases.values) {
      next.loadSnapshot(snap);
    }
    for (final op in ops()) {
      if (!drop.contains(op.opId)) next.apply(op);
    }
    return next;
  }

  /// Forgets a record entirely (it left this device's scope), except ops in [keep].
  Replica forget(String record, Set<OpId> keep) {
    final next = Replica(schema);
    for (final e in _bases.entries) {
      if (e.key != record) next.loadSnapshot(e.value);
    }
    for (final op in ops()) {
      if (op.record != record || keep.contains(op.opId)) next.apply(op);
    }
    return next;
  }

  /// Snapshots this replica was started from (to persist them alongside the ops).
  List<RecordSnapshot> bases() => _bases.values.toList();

  FieldState _state(String record, String field) => (_records[record] ??= {}).putIfAbsent(
    field,
    () => emptyState(strategyFor(schema, record, field)),
  );
}
