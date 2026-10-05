import 'errors.dart';
import 'op.dart';

/// How a field merges concurrent writes. Port of `schema.ts`.
enum Strategy {
  /// Highest clock wins. For names, notes and simple scalars.
  lww,

  /// Sum of all increments; none is ever lost. For quantities and stock adjustments.
  counter,

  /// Add-wins set of strings or numbers. For tags and assigned agents.
  set,

  /// Concurrent values are all kept and the field is flagged; the app resolves it. Never guesses.
  conflict,
}

/// `lww()`, `counter()`, `set()`, `conflict()`: the same declarations as the TypeScript schema.
Strategy lww() => Strategy.lww;
Strategy counter() => Strategy.counter;
Strategy set() => Strategy.set;
Strategy conflict() => Strategy.conflict;

/// Record type → field → strategy.
typedef Schema = Map<String, Map<String, Strategy>>;

/// The op kinds each strategy accepts.
const Map<Strategy, List<String>> kinds = {
  Strategy.lww: ['assign'],
  Strategy.conflict: ['assign'],
  Strategy.counter: ['inc'],
  Strategy.set: ['add', 'remove'],
};

final RegExp _type = RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,63}$');

/// Checks and returns a schema.
Schema defineSchema(Schema schema) {
  for (final type in schema.keys) {
    if (!_type.hasMatch(type)) throw AccordException('invalid record type "$type"');
  }
  return schema;
}

/// The strategy for `record.field`, or an error naming what is wrong.
Strategy strategyFor(Schema schema, String record, String field) {
  final fields = fieldsOf(schema, record);
  final s = fields[field];
  if (s == null) throw AccordException('unknown field "${recordType(record)}.$field"');
  return s;
}

Map<String, Strategy> fieldsOf(Schema schema, String record) {
  final type = recordType(record);
  final fields = schema[type];
  if (fields == null) throw AccordException('unknown record type "$type"');
  return fields;
}
