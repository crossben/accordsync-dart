import 'errors.dart';
import 'hlc.dart';
import 'op.dart';
import 'schema.dart';

/// Per-field state. Each strategy's [applyOp] is commutative and associative over distinct ops:
/// any delivery order of the same ops gives the same state. The replica applies each op at most
/// once, which makes the merge idempotent. Port of `strategies.ts`.
sealed class FieldState {
  Strategy get strategy;
}

final class LwwState extends FieldState {
  AssignOp? winner;
  @override
  Strategy get strategy => Strategy.lww;
}

final class CounterState extends FieldState {
  int total = 0;
  @override
  Strategy get strategy => Strategy.counter;
}

final class SetState extends FieldState {
  /// tag (the op id of the add) → element
  final Map<OpId, Object> tags = {};
  final Set<OpId> removed = {};
  @override
  Strategy get strategy => Strategy.set;
}

final class ConflictState extends FieldState {
  final Map<OpId, Object?> live = {};
  final Set<OpId> superseded = {};
  @override
  Strategy get strategy => Strategy.conflict;
}

FieldState emptyState(Strategy strategy) => switch (strategy) {
  Strategy.lww => LwwState(),
  Strategy.counter => CounterState(),
  Strategy.set => SetState(),
  Strategy.conflict => ConflictState(),
};

/// Applies [op] to [state] in place. The op must already be validated against the schema.
void applyOp(FieldState state, Op op) {
  switch ((state, op)) {
    case (final LwwState s, final AssignOp o):
      final w = s.winner;
      if (w == null || o.hlc.compareTo(w.hlc) > 0) s.winner = o;
    case (final CounterState s, final IncOp o):
      s.total += o.by;
    case (final SetState s, final AddOp o):
      for (final tag in o.deps) {
        s.removed.add(tag);
        s.tags.remove(tag);
      }
      if (!s.removed.contains(o.opId)) s.tags[o.opId] = o.element;
    case (final SetState s, final RemoveOp o):
      for (final tag in o.deps) {
        s.removed.add(tag);
        s.tags.remove(tag);
      }
    case (final ConflictState s, final AssignOp o):
      for (final dep in o.deps) {
        s.superseded.add(dep);
        s.live.remove(dep);
      }
      if (!s.superseded.contains(o.opId)) s.live[o.opId] = o.value;
    default:
      throw AccordException(
        'op kind "${op.kind}" does not apply to a ${state.strategy.name} field',
      );
  }
}

/// Marks a field with no value (never written): left out of reads and snapshots, like JavaScript's
/// `undefined`. A field written with `null` reads as `null`.
const Object absent = _Absent();

final class _Absent {
  const _Absent();
}

/// A field as the app sees it: a JSON value, a sorted list (set), an int (counter), or for a
/// `conflict()` field `{'value': v}` / `{'conflicted': [{'value': v, 'opId': id}, …]}`. [absent]
/// when never written.
Object? readState(FieldState state) => switch (state) {
  final LwwState s => s.winner == null ? absent : s.winner!.value,
  final CounterState s => s.total,
  final SetState s => (s.tags.values.toSet().toList()..sort(compareElements)),
  final ConflictState s => _readConflict(s),
};

Object? _readConflict(ConflictState s) {
  final live = s.live.entries.toList()..sort((a, b) => compareOpIds(a.key, b.key));
  if (live.isEmpty) return absent;
  if (live.length == 1) return {'value': live.first.value};
  return {
    'conflicted': [
      for (final e in live) {'value': e.value, 'opId': e.key},
    ],
  };
}

/// Op ids a writer must cite in `deps`: live conflict values, or the tags of a set element.
List<OpId> fieldObservedDeps(FieldState state, [Object? element]) => switch (state) {
  final ConflictState s => s.live.keys.toList()..sort(compareOpIds),
  final SetState s => [
    for (final e in s.tags.entries)
      if (sameElement(e.value, element)) e.key,
  ]..sort(compareOpIds),
  _ => <OpId>[],
};

/// Set elements compare like JavaScript's `===`: `1` and `1.0` are the same element.
bool sameElement(Object? a, Object? b) => (a is num && b is num) ? a == b : a == b;

/// Numbers first (ascending), then strings (by UTF-16 code unit), as in the TypeScript core.
int compareElements(Object a, Object b) {
  if (a is num && b is! num) return -1;
  if (a is! num && b is num) return 1;
  if (a is num && b is num) return a < b ? -1 : (a > b ? 1 : 0);
  return (a as String).compareTo(b as String).sign;
}

/// A field's live state as JSON; tombstones are dropped (ADR-0008). Same shape as the TypeScript
/// `FieldSnapshot`, so snapshots from the server load here unchanged.
Map<String, Object?> snapshotState(FieldState state) => switch (state) {
  final LwwState s => {
    'strategy': 'lww',
    'winner': s.winner == null
        ? null
        : {'opId': s.winner!.opId, 'hlc': s.winner!.hlc.encode(), 'value': s.winner!.value},
  },
  final CounterState s => {'strategy': 'counter', 'total': s.total},
  final SetState s => {
    'strategy': 'set',
    'tags': [
      for (final e in s.tags.entries.toList()..sort((a, b) => compareOpIds(a.key, b.key)))
        [e.key, e.value],
    ],
  },
  final ConflictState s => {
    'strategy': 'conflict',
    'live': [
      for (final e in s.live.entries.toList()..sort((a, b) => compareOpIds(a.key, b.key)))
        [e.key, e.value],
    ],
  },
};

FieldState stateFromSnapshot(Map<String, Object?> snap) {
  switch (snap['strategy']) {
    case 'lww':
      final w = snap['winner'] as Map<String, Object?>?;
      return LwwState()
        ..winner = w == null
            ? null
            : AssignOp(
                opId: w['opId'] as String,
                record: '',
                field: '',
                hlc: Hlc.decode(w['hlc'] as String),
                value: w['value'],
                deps: const [],
              );
    case 'counter':
      return CounterState()..total = (snap['total'] as num).toInt();
    case 'set':
      final s = SetState();
      for (final pair in snap['tags'] as List<Object?>) {
        final p = pair as List<Object?>;
        s.tags[p[0] as String] = p[1] as Object;
      }
      return s;
    case 'conflict':
      final s = ConflictState();
      for (final pair in snap['live'] as List<Object?>) {
        final p = pair as List<Object?>;
        s.live[p[0] as String] = p[1];
      }
      return s;
    default:
      throw AccordException('unknown snapshot strategy ${snap['strategy']}');
  }
}
