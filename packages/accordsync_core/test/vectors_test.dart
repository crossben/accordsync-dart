import 'dart:convert';
import 'dart:io';

import 'package:accordsync_core/accordsync_core.dart';
import 'package:test/test.dart';

import 'support.dart';

/// The golden vectors shared with `@accordsync/core`: every case, in every delivery order, each op
/// delivered twice, must read exactly the expected canonical snapshot.
Schema schemaFromJson(Map<String, Object?> json) => defineSchema({
  for (final t in json.entries)
    t.key: {
      for (final f in (t.value! as Map<String, Object?>).entries)
        f.key: Strategy.values.byName(f.value! as String),
    },
});

Iterable<List<T>> permutations<T>(List<T> xs) sync* {
  if (xs.length <= 1) {
    yield xs;
    return;
  }
  for (var i = 0; i < xs.length; i++) {
    for (final p in permutations([...xs.sublist(0, i), ...xs.sublist(i + 1)])) {
      yield [xs[i], ...p];
    }
  }
}

void main() {
  final dir = Directory('${contractDir().path}/vectors');
  final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  for (final file in files) {
    final name = file.uri.pathSegments.last;
    final v = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    final schema = schemaFromJson(v['schema']! as Map<String, Object?>);
    for (final c in (v['cases']! as List<Object?>).cast<Map<String, Object?>>()) {
      test('$name: ${c['name']}', () {
        expect(v['version'], 1);
        final ops = (c['ops']! as List<Object?>).map(decodeOp).toList();
        final expected = canonicalJson(c['expected']);
        var orders = 0;
        for (final order in permutations(ops)) {
          final r = Replica(schema);
          for (final op in [...order, ...order]) {
            r.apply(op);
          }
          expect(r.snapshot(), expected, reason: order.map((o) => o.opId).join(' '));
          orders++;
        }
        expect(orders, greaterThan(0));
      });
    }
  }
}
