import 'package:accordsync_core/accordsync_core.dart';
import 'package:test/test.dart';

/// Port of `writer.test.ts`.
final schema = defineSchema({
  'dossier': {'client_name': lww(), 'documents': set(), 'visits': counter(), 'status': conflict()},
});

LocalWriter device(String id, [int start = 1000]) {
  var now = start;
  return LocalWriter(schema: schema, deviceId: id, now: () => now++);
}

Matcher throwsMatching(String pattern) =>
    throwsA(isA<AccordException>().having((e) => e.message, 'message', matches(RegExp(pattern))));

void main() {
  test('numbers ops per device and stamps increasing clocks', () {
    final a = device('a');
    final o1 = a.assign('dossier:1', 'client_name', 'Awa');
    final o2 = a.assign('dossier:1', 'client_name', 'Awa Diop');
    expect([o1.opId, o2.opId], ['a:1', 'a:2']);
    expect(o2.hlc.compareTo(o1.hlc), greaterThan(0));
    expect(a.replica.read('dossier:1')!['client_name'], 'Awa Diop');
  });

  test('reads defaults for untouched fields, and leaves never-written ones out', () {
    final a = device('a');
    a.inc('dossier:1', 'visits', 2);
    expect(a.replica.read('dossier:1'), {'documents': <Object?>[], 'visits': 2});
    expect(a.replica.read('dossier:404'), isNull);
  });

  test('a field assigned null reads as null', () {
    final a = device('a');
    a.assign('dossier:1', 'client_name', null);
    expect(a.replica.read('dossier:1'), containsPair('client_name', null));
  });

  test('rejects writes that do not match the schema', () {
    final a = device('a');
    expect(() => a.assign('dossier:1', 'nope', 1), throwsMatching('unknown field'));
    expect(() => a.assign('ghost:1', 'x', 1), throwsMatching('unknown record type'));
    expect(() => a.inc('dossier:1', 'client_name', 1), throwsMatching('lww'));
    expect(() => a.add('dossier:1', 'documents', {'a': 1}), throwsMatching('string or number'));
  });

  test('sets: remove only removes what the writer has seen (add wins)', () {
    final a = device('a'), b = device('b');
    final add = a.add('dossier:1', 'documents', 'cni.pdf');
    b.receive(add);
    final remove = b.remove('dossier:1', 'documents', 'cni.pdf');
    final readd = a.add('dossier:1', 'documents', 'cni.pdf'); // concurrent with the remove
    a.receive(remove);
    b.receive(readd);
    expect(a.replica.read('dossier:1')!['documents'], ['cni.pdf']);
    expect(b.replica.read('dossier:1')!['documents'], ['cni.pdf']);
  });

  test('sets: 1 and 1.0 are the same element, as in JavaScript', () {
    final a = device('a');
    a.add('dossier:1', 'documents', 1);
    a.remove('dossier:1', 'documents', 1.0);
    expect(a.replica.read('dossier:1')!['documents'], isEmpty);
  });

  test('conflict(): concurrent assigns surface both values; nothing is guessed', () {
    final a = device('a'), b = device('b');
    final x = a.assign('dossier:1', 'status', 'approved');
    final y = b.assign('dossier:1', 'status', 'rejected');
    a.receive(y);
    b.receive(x);
    for (final r in [a.replica, b.replica]) {
      expect(r.read('dossier:1')!['status'], {
        'conflicted': [
          {'value': 'approved', 'opId': 'a:1'},
          {'value': 'rejected', 'opId': 'b:1'},
        ],
      });
      expect(r.conflicts(), [(record: 'dossier:1', field: 'status')]);
    }
  });

  test('conflict(): a sequential edit replaces the value it saw, without a conflict', () {
    final a = device('a'), b = device('b');
    b.receive(a.assign('dossier:1', 'status', 'draft'));
    a.receive(b.assign('dossier:1', 'status', 'submitted'));
    expect(a.replica.read('dossier:1')!['status'], {'value': 'submitted'});
    expect(a.replica.conflicts(), isEmpty);
  });

  test('conflict(): resolving keeps an edit the resolver had not seen', () {
    final a = device('a'), b = device('b'), c = device('c');
    final x = a.assign('dossier:1', 'status', 'approved');
    final y = b.assign('dossier:1', 'status', 'rejected');
    final z = c.assign('dossier:1', 'status', 'on_hold'); // c is offline the whole time
    a.receive(y);
    final resolution = a.assign('dossier:1', 'status', 'approved'); // resolves x and y
    expect(resolution.deps, ['a:1', 'b:1']);
    for (final op in [resolution, z, x]) {
      b.receive(op);
    }
    expect(b.replica.read('dossier:1')!['status'], {
      'conflicted': [
        {'value': 'approved', 'opId': 'a:2'},
        {'value': 'on_hold', 'opId': 'c:1'},
      ],
    });
  });

  test('counts every increment, including negative ones', () {
    final a = device('a'), b = device('b');
    final ops = [a.inc('dossier:1', 'visits', 3), b.inc('dossier:1', 'visits', -1)];
    a.receive(ops[1]);
    b.receive(ops[0]);
    expect(a.replica.read('dossier:1')!['visits'], 2);
    expect(b.replica.read('dossier:1')!['visits'], 2);
  });

  test('ignores a duplicate op', () {
    final a = device('a'), b = device('b');
    final op = a.inc('dossier:1', 'visits', 5);
    expect(b.receive(op), ApplyResult.applied);
    expect(b.receive(op), ApplyResult.duplicate);
    expect(b.replica.read('dossier:1')!['visits'], 5);
  });

  test('lww: highest clock wins regardless of arrival order', () {
    final a = device('a', 1000), b = device('b', 5000); // b's clock is ahead
    final x = b.assign('dossier:1', 'client_name', 'from b');
    final y = a.assign('dossier:1', 'client_name', 'from a');
    a.receive(x);
    b.receive(y);
    expect(a.replica.read('dossier:1')!['client_name'], 'from b');
    expect(b.replica.read('dossier:1')!['client_name'], 'from b');
  });

  test('refuses an op from a clock too far ahead and leaves state untouched', () {
    final a = LocalWriter(schema: schema, deviceId: 'a', now: () => 1000, maxSkewMs: 60000);
    final liar = LocalWriter(schema: schema, deviceId: 'liar', now: () => 10000000);
    expect(() => a.receive(liar.inc('dossier:1', 'visits', 1)), throwsA(isA<ClockSkewException>()));
    expect(a.replica.read('dossier:1'), isNull);
  });

  test('discard rolls back a refused op and keeps the rest', () {
    final a = device('a');
    final keep = a.inc('dossier:1', 'visits', 2);
    final refused = a.inc('dossier:1', 'visits', 40);
    a.assign('dossier:2', 'status', 'approved');
    a.discard([refused.opId]);
    expect(a.replica.read('dossier:1')!['visits'], 2);
    expect(a.replica.has(keep.opId), isTrue);
    expect(a.replica.has(refused.opId), isFalse);
    expect(a.replica.read('dossier:2')!['status'], {'value': 'approved'});
    expect(a.inc('dossier:1', 'visits', 1).opId, 'a:4'); // op ids are never reused
  });

  test('never reuses an op id after receiving its own old ops (fresh storage, same id)', () {
    final before = device('a');
    final old = [before.inc('dossier:1', 'visits', 1), before.inc('dossier:1', 'visits', 2)];
    final reinstalled = device('a');
    for (final op in old) {
      reinstalled.receive(op);
    }
    expect(reinstalled.inc('dossier:1', 'visits', 4).opId, 'a:3');
    expect(reinstalled.replica.read('dossier:1')!['visits'], 7);
  });

  test('sets: re-adding a present element replaces the tags its writer saw', () {
    final a = device('a'), b = device('b');
    for (var i = 0; i < 50; i++) {
      a.add('dossier:1', 'documents', 'cni.pdf');
    }
    expect(a.replica.observedDeps('dossier:1', 'documents', 'cni.pdf'), hasLength(1));
    for (final op in a.replica.ops()) {
      b.receive(op);
    }
    final remove = b.remove('dossier:1', 'documents', 'cni.pdf');
    final readd = a.add('dossier:1', 'documents', 'cni.pdf');
    a.receive(remove);
    b.receive(readd);
    expect(a.replica.read('dossier:1')!['documents'], ['cni.pdf']);
    expect(b.replica.read('dossier:1')!['documents'], ['cni.pdf']);
  });

  test('forget drops a record except the kept local ops', () {
    final a = device('a');
    final mine = a.inc('dossier:1', 'visits', 1);
    a.inc('dossier:1', 'visits', 2);
    a.inc('dossier:2', 'visits', 3);
    a.forget('dossier:1', {mine.opId});
    expect(a.replica.read('dossier:1')!['visits'], 1);
    expect(a.replica.read('dossier:2')!['visits'], 3);
  });
}
