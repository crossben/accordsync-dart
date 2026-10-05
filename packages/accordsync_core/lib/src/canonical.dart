import 'dart:convert';

/// JSON with object keys in a canonical order, so equal values always serialise to the same string.
///
/// Byte-for-byte identical to the TypeScript `canonicalJson` (`JSON.stringify` of an object built
/// from key-sorted entries). That means reproducing JavaScript, not just sorting keys:
/// - keys that are array indices ("0", "9", "10"…) come first, in numeric order, because JavaScript
///   objects always order them that way; the other keys follow, sorted by UTF-16 code unit;
/// - numbers print as JavaScript prints them: `1` not `1.0`, `0` for `-0.0`, `1e+21`, `1e-7`;
/// - strings escape exactly like `JSON.stringify` (Dart's encoder already does).
String canonicalJson(Object? value) {
  final out = StringBuffer();
  _write(out, value);
  return out.toString();
}

void _write(StringBuffer out, Object? value) {
  switch (value) {
    case null:
      out.write('null');
    case final bool b:
      out.write(b ? 'true' : 'false');
    case final num n:
      out.write(jsNumber(n));
    case final String s:
      out.write(jsonEncode(s));
    case final List<Object?> list:
      out.write('[');
      for (var i = 0; i < list.length; i++) {
        if (i > 0) out.write(',');
        _write(out, list[i]);
      }
      out.write(']');
    case final Map<String, Object?> map:
      out.write('{');
      var first = true;
      for (final key in jsKeyOrder(map.keys)) {
        if (!first) out.write(',');
        first = false;
        out
          ..write(jsonEncode(key))
          ..write(':');
        _write(out, map[key]);
      }
      out.write('}');
    default:
      throw ArgumentError('canonicalJson: not a JSON value: ${value.runtimeType}');
  }
}

final RegExp _arrayIndex = RegExp(r'^(0|[1-9]\d*)$');
const int _maxArrayIndex = 4294967294;

/// The order JavaScript gives the keys of an object built from code-unit-sorted entries.
List<String> jsKeyOrder(Iterable<String> keys) {
  final indices = <String>[];
  final others = <String>[];
  for (final k in keys) {
    if (_arrayIndex.hasMatch(k) && k.length <= 10 && int.parse(k) <= _maxArrayIndex) {
      indices.add(k);
    } else {
      others.add(k);
    }
  }
  indices.sort((a, b) => int.parse(a).compareTo(int.parse(b)));
  others.sort();
  return [...indices, ...others];
}

/// A number as `JSON.stringify` prints it.
String jsNumber(num n) {
  if (n is int) return n.toString();
  final d = n as double;
  if (!d.isFinite) return 'null';
  if (d == 0) return '0';
  final s = d.toString();
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}
