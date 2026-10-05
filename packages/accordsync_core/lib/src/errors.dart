/// An op, record or schema that Accord refuses, with the reason.
class AccordException implements Exception {
  AccordException(this.message);
  final String message;
  @override
  String toString() => 'AccordException: $message';
}

/// A remote clock too far ahead of this one: the op is refused instead of winning every merge.
class ClockSkewException extends AccordException {
  ClockSkewException(super.message);
  @override
  String toString() => 'ClockSkewException: $message';
}
