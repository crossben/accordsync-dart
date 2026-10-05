import 'errors.dart';
import 'hlc.dart';
import 'op.dart';

/// An op as it travels over the network and sits in golden vectors. Port of `wire.ts`.
Map<String, Object?> encodeOp(Op op) {
  final base = <String, Object?>{
    'op_id': op.opId,
    'record': op.record,
    'field': op.field,
    'hlc': op.hlc.encode(),
  };
  return switch (op) {
    final AssignOp o => {
      ...base,
      'kind': 'assign',
      'value': o.value,
      'deps': [...o.deps],
    },
    final IncOp o => {...base, 'kind': 'inc', 'by': o.by},
    // `deps` is omitted when empty, so first adds keep the v0.1 wire shape.
    final AddOp o => {
      ...base,
      'kind': 'add',
      'element': o.element,
      if (o.deps.isNotEmpty) 'deps': [...o.deps],
    },
    final RemoveOp o => {
      ...base,
      'kind': 'remove',
      'element': o.element,
      'deps': [...o.deps],
    },
  };
}

/// Parses untrusted input into an op, or throws with the reason. Schema checks happen later.
Op decodeOp(Object? input) {
  if (input is! Map) throw AccordException('op must be an object');
  final o = input;
  final opId = _str(o, 'op_id');
  final record = _str(o, 'record');
  final field = _str(o, 'field');
  final hlc = Hlc.decode(_str(o, 'hlc'));
  final device = parseOpId(opId).device;
  recordType(record);
  if (device != hlc.node) throw AccordException('op $opId carries a clock from "${hlc.node}"');
  switch (o['kind']) {
    case 'assign':
      if (!o.containsKey('value')) throw AccordException('assign needs a value');
      return AssignOp(
        opId: opId,
        record: record,
        field: field,
        hlc: hlc,
        value: o['value'],
        deps: _deps(o),
      );
    case 'inc':
      final by = o['by'];
      // JSON decoders may hand a whole number over as a double (`3.0`); JavaScript sees one number.
      final int? n = by is int
          ? by
          : (by is double && by == by.truncateToDouble() ? by.toInt() : null);
      if (n == null || n.abs() > maxSafeInteger) {
        throw AccordException('inc needs an integer "by"');
      }
      return IncOp(opId: opId, record: record, field: field, hlc: hlc, by: n);
    case 'add':
      return AddOp(
        opId: opId,
        record: record,
        field: field,
        hlc: hlc,
        element: _element(o),
        deps: o.containsKey('deps') ? _deps(o) : const [],
      );
    case 'remove':
      return RemoveOp(
        opId: opId,
        record: record,
        field: field,
        hlc: hlc,
        element: _element(o),
        deps: _deps(o),
      );
    default:
      throw AccordException('unknown op kind ${o['kind']}');
  }
}

String _str(Map<dynamic, dynamic> o, String key) {
  final v = o[key];
  if (v is! String) throw AccordException('"$key" must be a string');
  return v;
}

List<OpId> _deps(Map<dynamic, dynamic> o) {
  final d = o['deps'];
  if (d is! List) throw AccordException('"deps" must be an array of op ids');
  for (final id in d) {
    if (id is! String) throw AccordException('"deps" must contain strings');
    parseOpId(id);
  }
  return List<OpId>.unmodifiable(d.cast<String>());
}

Object _element(Map<dynamic, dynamic> o) {
  final e = o['element'];
  if (e is String) return e;
  if (e is num && e.isFinite) return e;
  throw AccordException('"element" must be a string or finite number');
}
