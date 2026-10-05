import 'errors.dart';
import 'hlc.dart';

/// `deviceId:sequence`. Unique per op, so applying an op twice is a no-op.
typedef OpId = String;

final RegExp _opId = RegExp(r'^([A-Za-z0-9_-]{1,64}):([1-9]\d{0,15})$');
final RegExp _recordId = RegExp(r'^([A-Za-z][A-Za-z0-9_]{0,63}):(.{1,256})$', dotAll: true);

/// One change to one field of one record. Port of `op.ts`.
///
/// Values are JSON: `null`, `bool`, `num`, `String`, `List<Object?>` or `Map<String, Object?>`.
/// Set elements are strings or numbers.
sealed class Op {
  const Op({required this.opId, required this.record, required this.field, required this.hlc});

  final OpId opId;

  /// `type:id`, for example `dossier:91`.
  final String record;
  final String field;
  final Hlc hlc;

  /// `assign`, `inc`, `add` or `remove`.
  String get kind;
}

/// Writes a value. For `lww` the highest clock wins; for `conflict`, [deps] lists the values the
/// writer could see, and the assign supersedes exactly those (ADR-0003).
final class AssignOp extends Op {
  const AssignOp({
    required super.opId,
    required super.record,
    required super.field,
    required super.hlc,
    required this.value,
    required this.deps,
  });
  final Object? value;
  final List<OpId> deps;
  @override
  String get kind => 'assign';
}

/// Adds [by] (a positive or negative integer) to a counter.
final class IncOp extends Op {
  const IncOp({
    required super.opId,
    required super.record,
    required super.field,
    required super.hlc,
    required this.by,
  });
  final int by;
  @override
  String get kind => 'inc';
}

/// Adds an element to a set; the op id is its tag. [deps] lists the element's tags the writer could
/// see: the add replaces them, while a concurrent remove still loses.
final class AddOp extends Op {
  const AddOp({
    required super.opId,
    required super.record,
    required super.field,
    required super.hlc,
    required this.element,
    required this.deps,
  });
  final Object element;
  final List<OpId> deps;
  @override
  String get kind => 'add';
}

/// Removes the add tags in [deps] (the ones the writer had seen); concurrent adds survive.
final class RemoveOp extends Op {
  const RemoveOp({
    required super.opId,
    required super.record,
    required super.field,
    required super.hlc,
    required this.element,
    required this.deps,
  });
  final Object element;
  final List<OpId> deps;
  @override
  String get kind => 'remove';
}

/// The device and sequence number of an op id.
({String device, int seq}) parseOpId(String opId) {
  final m = _opId.firstMatch(opId);
  if (m == null) throw AccordException('malformed op id "$opId" (expected device:sequence)');
  return (device: m.group(1)!, seq: int.parse(m.group(2)!));
}

/// The type of a record id (`dossier` for `dossier:91`).
String recordType(String record) {
  final m = _recordId.firstMatch(record);
  if (m == null) throw AccordException('malformed record id "$record" (expected type:id)');
  return m.group(1)!;
}

/// Sort order for op ids: UTF-16 code units, exactly like JavaScript's `<` on strings.
int compareOpIds(OpId a, OpId b) => a.compareTo(b).sign;
