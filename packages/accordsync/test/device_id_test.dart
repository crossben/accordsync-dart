import 'dart:math';

import 'package:accordsync/accordsync.dart';
import 'package:test/test.dart';

void main() {
  test('device ids are 32 random hex digits behind a letter, valid as op id prefixes', () {
    final ids = {for (var i = 0; i < 100; i++) randomDeviceId()};
    expect(ids, hasLength(100));
    for (final id in ids) {
      expect(id, matches(RegExp(r'^d[0-9a-f]{32}$')));
      expect(() => assertNode(id), returnsNormally);
    }
  });

  test('takes the random source it is given', () {
    expect(randomDeviceId(_Fixed()), 'd${'ab' * 16}');
  });
}

class _Fixed implements Random {
  @override
  int nextInt(int max) => 0xab;
  @override
  bool nextBool() => true;
  @override
  double nextDouble() => 0;
}
