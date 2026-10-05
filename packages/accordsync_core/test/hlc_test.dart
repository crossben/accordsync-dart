import 'dart:math';

import 'package:accordsync_core/accordsync_core.dart';
import 'package:test/test.dart';

/// Port of `hlc.test.ts`, with seeded random inputs in place of fast-check.
void main() {
  final rnd = Random(42);
  Hlc randomHlc([String? node]) => Hlc(
    rnd.nextInt(1 << 32) * 900 + rnd.nextInt(900),
    rnd.nextInt(maxCounter + 1),
    node ?? 'n${rnd.nextInt(1000)}',
  );

  test('round-trips through its wire encoding', () {
    for (var i = 0; i < 500; i++) {
      final h = randomHlc();
      expect(Hlc.decode(h.encode()), h);
    }
  });

  test('encodes in the documented format', () {
    expect(Hlc(1727871000123, 4, 'dev-7f3a').encode(), '1727871000123:00004:dev-7f3a');
  });

  test('rejects malformed encodings', () {
    for (final bad in ['', '1:2', 'x:00001:a', '1:00001:', '-1:00001:a', '1:00001:a:b']) {
      expect(() => Hlc.decode(bad), throwsA(isA<AccordException>()), reason: bad);
    }
  });

  test('orders totally and antisymmetrically', () {
    for (var i = 0; i < 500; i++) {
      final a = randomHlc(), b = i.isEven ? randomHlc() : Hlc(a.wall, a.counter, 'z');
      expect(a.compareTo(b).sign, -b.compareTo(a).sign);
      if (a.compareTo(b) == 0) expect(a, b);
    }
  });

  test('tick is strictly increasing even when the wall clock goes backwards', () {
    var h = Hlc.initial('a');
    for (var i = 0; i < 1000; i++) {
      final next = h.tick(rnd.nextInt(10000));
      expect(next.compareTo(h), greaterThan(0));
      h = next;
    }
  });

  test('receive moves past both the local and the remote clock', () {
    for (var i = 0; i < 500; i++) {
      final local = randomHlc('local'), remote = randomHlc();
      final next = local.receive(remote, rnd.nextInt(1 << 32) * 900, maxSafeInteger);
      expect(next.compareTo(local), greaterThan(0));
      expect(
        next.wall > remote.wall || (next.wall == remote.wall && next.counter > remote.counter),
        isTrue,
      );
      expect(next.node, 'local');
    }
  });

  test('a full counter rolls into the next millisecond instead of failing', () {
    expect(Hlc(5, maxCounter, 'a').tick(0), Hlc(6, 0, 'a'));
    expect(Hlc.initial('a').receive(Hlc(5, maxCounter, 'b'), 0, 1000), Hlc(6, 0, 'a'));
  });

  test('refuses a remote clock too far in the future', () {
    final local = Hlc.initial('a');
    final remote = Hlc(10000000, 0, 'b');
    expect(() => local.receive(remote, 1000, 60000), throwsA(isA<ClockSkewException>()));
    expect(() => local.receive(remote, 9990000, 60000), returnsNormally);
  });
}
