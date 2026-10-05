import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:accordsync_core/accordsync_core.dart';
import 'package:test/test.dart';

/// Strategy laws, checked against reference models. Port of `laws.test.ts`, with a seeded
/// generator in place of fast-check.
///
/// Random devices write and partially sync. Every op ever made is then replayed into fresh replicas
/// in shuffled orders, with duplicates. The tests assert order independence and idempotency,
/// convergence, that each strategy matches its definition, and that compaction (snapshot, then the
/// remaining ops) reads the same as the full log.
final schema = defineSchema({
  'dossier': {'name': lww(), 'docs': set(), 'visits': counter(), 'status': conflict()},
});

final runs = int.tryParse(Platform.environment['ACCORD_PROPERTY_RUNS'] ?? '') ?? 300;

({List<LocalWriter> devs, List<Op> all}) scenario(Random rnd) {
  var tick = 1700000000000;
  final devs = [
    for (var i = 0, n = 2 + rnd.nextInt(3); i < n; i++)
      // Phone clocks are wrong: each device runs up to an hour fast or slow.
      () {
        final skew = rnd.nextInt(7200001) - 3600000;
        return LocalWriter(schema: schema, deviceId: 'd$i', now: () => (tick += 7) + skew);
      }(),
  ];
  final all = <Op>[];
  for (var i = 0, n = rnd.nextInt(61); i < n; i++) {
    if (rnd.nextBool()) {
      final w = devs[rnd.nextInt(devs.length)];
      final rec = 'dossier:${rnd.nextInt(2)}';
      final v = rnd.nextInt(7) - 3;
      switch (rnd.nextInt(4)) {
        case 0:
          all.add(w.assign(rec, 'name', 'n$v'));
        case 1:
          all.add(w.assign(rec, 'status', 's$v'));
        case 2:
          all.add(w.inc(rec, 'visits', v));
        default:
          final el = 'doc${v.abs() % 3}';
          all.add(rnd.nextBool() ? w.remove(rec, 'docs', el) : w.add(rec, 'docs', el));
      }
    } else {
      // Deliver an arbitrary subset, in log order: partial syncs and lost messages.
      final from = devs[rnd.nextInt(devs.length)], to = devs[rnd.nextInt(devs.length)];
      for (final op in from.replica.ops()) {
        if (rnd.nextBool()) to.receive(op);
      }
    }
  }
  return (devs: devs, all: all);
}

Replica replay(Iterable<Op> ops) {
  final r = Replica(schema);
  for (final op in ops) {
    r.apply(op);
  }
  return r;
}

/// Reference models, computed straight from the definitions over the full op set.
Map<String, Object?> model(List<Op> all, String record) {
  final mine = all.where((o) => o.record == record);
  Iterable<Op> of(String f) => mine.where((o) => o.field == f);

  AssignOp? winner;
  for (final o in of('name').cast<AssignOp>()) {
    if (winner == null || o.hlc.compareTo(winner.hlc) > 0) winner = o;
  }
  final visits = of('visits').cast<IncOp>().fold(0, (sum, o) => sum + o.by);
  final removed = {
    for (final o in of('docs'))
      ...switch (o) {
        AddOp(:final deps) || RemoveOp(:final deps) => deps,
        _ => const <OpId>[],
      },
  };
  final docs = {
    for (final o in of('docs'))
      if (o case AddOp(:final opId, :final element) when !removed.contains(opId)) element,
  }.cast<String>().toList()..sort();
  final statuses = of('status').cast<AssignOp>();
  final superseded = {for (final o in statuses) ...o.deps};
  final live = statuses.where((o) => !superseded.contains(o.opId)).toList()
    ..sort((a, b) => a.opId.compareTo(b.opId));

  return {
    if (winner != null) 'name': winner.value,
    'docs': docs,
    'visits': visits,
    if (live.length == 1) 'status': {'value': live.single.value},
    if (live.length > 1)
      'status': {
        'conflicted': [
          for (final o in live) {'value': o.value, 'opId': o.opId},
        ],
      },
  };
}

void main() {
  test('any delivery order, with duplicates, reads the same state', () {
    for (var seed = 0; seed < runs; seed++) {
      final rnd = Random(seed);
      final all = scenario(rnd).all;
      final reference = replay(all).snapshot();
      for (var k = 0; k < 3; k++) {
        final withDuplicates = [...all, ...all.take(rnd.nextInt(5))]..shuffle(rnd);
        expect(replay(withDuplicates).snapshot(), reference, reason: 'seed $seed');
      }
    }
  });

  test('devices converge once every op is delivered', () {
    for (var seed = 0; seed < runs; seed++) {
      final rnd = Random(seed);
      final (:devs, :all) = scenario(rnd);
      for (final d in devs) {
        for (final op in [...all]..shuffle(rnd)) {
          d.receive(op);
        }
      }
      final reference = replay(all).snapshot();
      for (final d in devs) {
        expect(d.replica.snapshot(), reference, reason: 'seed $seed');
      }
    }
  });

  test('each strategy matches its definition', () {
    for (var seed = 0; seed < runs; seed++) {
      final rnd = Random(seed);
      final all = scenario(rnd).all;
      final r = replay([...all]..shuffle(rnd));
      for (final record in r.records()) {
        expect(r.read(record), model(all, record), reason: 'seed $seed, $record');
      }
    }
  });

  test('compaction: a snapshot plus the later ops reads like the whole log', () {
    for (var seed = 0; seed < runs; seed++) {
      final rnd = Random(seed);
      final all = scenario(rnd).all;
      // Ops in creation order are causally ordered, so every prefix is causally closed.
      final cut = all.isEmpty ? 0 : rnd.nextInt(all.length + 1);
      final before = replay(all.take(cut));
      final compacted = Replica(schema);
      for (final record in before.records()) {
        // Through JSON, as a snapshot travels from the server.
        compacted.loadSnapshot(
          RecordSnapshot.fromJson(
            jsonRoundTrip(before.snapshotRecord(record).toJson()) as Map<String, Object?>,
          ),
        );
      }
      for (final op in all.skip(cut)) {
        compacted.apply(op);
      }
      expect(compacted.snapshot(), replay(all).snapshot(), reason: 'seed $seed, cut $cut');
    }
  });

  test('a conflict() field written concurrently is never auto-resolved', () {
    final rnd = Random(7);
    for (var i = 0; i < runs; i++) {
      final x = 'x${rnd.nextInt(1000)}', y = 'y${rnd.nextInt(1000)}';
      var t = 0;
      final a = LocalWriter(schema: schema, deviceId: 'a', now: () => t++);
      final b = LocalWriter(schema: schema, deviceId: 'b', now: () => t++);
      final ops = [a.assign('dossier:1', 'status', x), b.assign('dossier:1', 'status', y)];
      a.receive(ops[1]);
      b.receive(ops[0]);
      for (final w in [a, b]) {
        expect(w.replica.conflicts(), [(record: 'dossier:1', field: 'status')]);
      }
    }
  });
}

Object? jsonRoundTrip(Object? v) => jsonDecode(jsonEncode(v));
