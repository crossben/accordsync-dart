import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:accordsync_core/accordsync_core.dart';
import 'package:test/test.dart';

import 'support.dart';
import 'vectors_test.dart' show schemaFromJson;

/// Random scenarios written by the TypeScript core (`random-vectors.test.ts`), with the snapshots
/// it read. This core must produce the same bytes: same merge, same canonical JSON (key order,
/// number and string formatting), in any delivery order, and the same compacted record snapshots.
void main() {
  final v =
      jsonDecode(File('${contractDir().path}/vectors/random/cases.json').readAsStringSync())
          as Map<String, Object?>;
  final schema = schemaFromJson(v['schema']! as Map<String, Object?>);
  final cases = (v['cases']! as List<Object?>).cast<Map<String, Object?>>();

  test('there are cases to check', () => expect(cases, hasLength(greaterThanOrEqualTo(40))));

  for (final c in cases) {
    test('seed ${c['seed']}', () {
      final ops = (c['ops']! as List<Object?>).map(decodeOp).toList();
      final rnd = Random(c['seed']! as int);
      for (var k = 0; k < 5; k++) {
        final order = k == 0 ? ops : ([...ops, ...ops.take(rnd.nextInt(5))]..shuffle(rnd));
        final r = Replica(schema);
        for (final op in order) {
          r.apply(op);
        }
        expect(r.snapshot(), c['snapshot'], reason: 'order $k');
        if (k == 0) {
          final records = c['records']! as Map<String, Object?>;
          expect(r.records(), records.keys.toList()..sort());
          for (final e in records.entries) {
            expect(canonicalJson(r.snapshotRecord(e.key).toJson()), e.value, reason: e.key);
          }
        }
      }
      // Wire round trip: re-encoding gives the ops back unchanged.
      expect(canonicalJson(ops.map(encodeOp).toList()), canonicalJson(c['ops']));
    });
  }
}
