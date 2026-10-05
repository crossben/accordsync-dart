import 'errors.dart';
import 'hlc.dart';
import 'op.dart';
import 'replica.dart';
import 'schema.dart';

const int defaultMaxSkewMs = 24 * 60 * 60 * 1000;

/// One device's replica plus the means to write to it: every local write becomes an op, applied
/// locally first and returned so the caller can queue it for sync. Port of `writer.ts`.
final class LocalWriter {
  /// [_now] gives physical time in ms; the core never reads the clock itself. Remote clocks further
  /// ahead than [_maxSkewMs] are refused. [resume] restores a device's last clock and sequence.
  LocalWriter({
    required Schema schema,
    required this.deviceId,
    required this._now,
    this._maxSkewMs = defaultMaxSkewMs,
    ({Hlc hlc, int seq})? resume,
  }) : _replica = Replica(schema),
       _hlc = resume?.hlc ?? Hlc.initial(deviceId),
       _seq = resume?.seq ?? 0 {
    assertNode(deviceId);
  }

  final String deviceId;
  final int Function() _now;
  final int _maxSkewMs;
  Replica _replica;
  Hlc _hlc;
  int _seq;

  Replica get replica => _replica;
  Hlc get clock => _hlc;
  int get seq => _seq;

  AssignOp assign(String record, String field, Object? value) {
    final deps = _replica.observedDeps(record, field);
    final b = _base(record, field);
    return _write(
      AssignOp(opId: b.opId, record: record, field: field, hlc: b.hlc, value: value, deps: deps),
    );
  }

  IncOp inc(String record, String field, int by) {
    if (by.abs() > maxSafeInteger) {
      throw AccordException('counter increment must be a safe integer, got $by');
    }
    final b = _base(record, field);
    return _write(IncOp(opId: b.opId, record: record, field: field, hlc: b.hlc, by: by));
  }

  AddOp add(String record, String field, Object element) {
    _assertElement(element);
    final deps = _replica.observedDeps(record, field, element);
    final b = _base(record, field);
    return _write(
      AddOp(opId: b.opId, record: record, field: field, hlc: b.hlc, element: element, deps: deps),
    );
  }

  RemoveOp remove(String record, String field, Object element) {
    _assertElement(element);
    final deps = _replica.observedDeps(record, field, element);
    final b = _base(record, field);
    return _write(
      RemoveOp(
        opId: b.opId,
        record: record,
        field: field,
        hlc: b.hlc,
        element: element,
        deps: deps,
      ),
    );
  }

  /// Applies an op from elsewhere. Refuses it, leaving state untouched, if its clock is absurd.
  ApplyResult receive(Op op) {
    if (_replica.has(op.opId)) {
      advanceSeq(op.opId);
      return ApplyResult.duplicate;
    }
    _replica.validate(op);
    final next = _hlc.receive(op.hlc, _now(), _maxSkewMs);
    final result = _replica.apply(op);
    _hlc = next;
    advanceSeq(op.opId);
    return result;
  }

  /// Makes sure future op ids come after [seenOrSeq]: an op id of this device (a `String`, as
  /// received from the server after a reinstall) or a sequence number (`int`) the server reports.
  /// Op ids are never reused.
  void advanceSeq(Object seenOrSeq) {
    final int seq;
    if (seenOrSeq is int) {
      seq = seenOrSeq;
    } else {
      final id = parseOpId(seenOrSeq as String);
      if (id.device != deviceId) return;
      seq = id.seq;
    }
    if (seq > _seq) _seq = seq;
  }

  /// Rolls back ops the server refused: the replica is rebuilt from its log without them. The clock
  /// and sequence number are not rewound; op ids are never reused.
  void discard(Iterable<OpId> opIds) => _replica = _replica.without(opIds.toSet());

  /// The record left this device's scope: forget it, except the local ops in [keep].
  void forget(String record, [Set<OpId> keep = const {}]) =>
      _replica = _replica.forget(record, keep);

  ({OpId opId, Hlc hlc}) _base(String record, String field) {
    // Validate before consuming a clock tick or sequence number.
    _replica.observedDeps(record, field);
    _hlc = _hlc.tick(_now());
    _seq += 1;
    return (opId: '$deviceId:$_seq', hlc: _hlc);
  }

  T _write<T extends Op>(T op) {
    _replica.apply(op);
    return op;
  }
}

void _assertElement(Object e) {
  if (e is! String && !(e is num && e.isFinite)) {
    throw AccordException('set elements must be a string or number');
  }
}
