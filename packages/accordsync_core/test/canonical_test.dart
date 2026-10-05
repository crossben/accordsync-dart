import 'package:accordsync_core/accordsync_core.dart';
import 'package:test/test.dart';

/// Canonical JSON must equal what `JSON.stringify` gives in the TypeScript core. The random vectors
/// cover most of it; these are the cases JSON input can never carry into Dart.
void main() {
  test('numbers print as JavaScript prints them', () {
    expect(canonicalJson(-0.0), '0');
    expect(canonicalJson(0.0), '0');
    expect(canonicalJson(1.0), '1');
    expect(canonicalJson(-2.0), '-2');
    expect(canonicalJson(0.1), '0.1');
    expect(canonicalJson(1e21), '1e+21');
    expect(canonicalJson(1e-7), '1e-7');
    expect(canonicalJson(123456789.125), '123456789.125');
    expect(canonicalJson(double.nan), 'null');
    expect(canonicalJson(double.infinity), 'null');
  });

  test('keys: array indices first in numeric order, then code-unit order', () {
    expect(
      canonicalJson({'b': 1, 'a': 2, '10': 3, '9': 4, '01': 5, '4294967295': 6, 'B': 7}),
      '{"9":4,"10":3,"01":5,"4294967295":6,"B":7,"a":2,"b":1}',
    );
  });

  test('strings escape like JSON.stringify', () {
    expect(
      canonicalJson('\u0000\n"\\ \ud800😀'),
      r'"\u0000\n\"\\'
      ' '
      r'\ud800'
      '😀"',
    );
  });
}
