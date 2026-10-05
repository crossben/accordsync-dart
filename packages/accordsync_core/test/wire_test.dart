import 'dart:convert';

import 'package:accordsync_core/accordsync_core.dart';
import 'package:test/test.dart';

/// Port of `wire.test.ts`.
void main() {
  final op = AssignOp(
    opId: 'dev-7f3a:1042',
    record: 'dossier:91',
    field: 'status',
    hlc: Hlc(1727871000123, 4, 'dev-7f3a'),
    value: 'submitted',
    deps: const ['dev-7f3a:1041'],
  );

  test('round-trips an op', () {
    final back = decodeOp(jsonDecode(jsonEncode(encodeOp(op)))) as AssignOp;
    expect(encodeOp(back), encodeOp(op));
  });

  test('matches the documented shape', () {
    expect(encodeOp(op), {
      'op_id': 'dev-7f3a:1042',
      'record': 'dossier:91',
      'field': 'status',
      'kind': 'assign',
      'value': 'submitted',
      'hlc': '1727871000123:00004:dev-7f3a',
      'deps': ['dev-7f3a:1041'],
    });
  });

  test('a first add leaves deps out, like the TypeScript encoder', () {
    final add = AddOp(
      opId: 'a:1',
      record: 'dossier:1',
      field: 'docs',
      hlc: Hlc(1, 0, 'a'),
      element: 'x',
      deps: const [],
    );
    expect(encodeOp(add).containsKey('deps'), isFalse);
    expect((decodeOp(encodeOp(add)) as AddOp).deps, isEmpty);
  });

  test('accepts a whole number sent as a double for inc', () {
    final good = {...encodeOp(op), 'kind': 'inc', 'by': 3.0};
    expect((decodeOp(good) as IncOp).by, 3);
  });

  test('rejects malformed ops with a reason', () {
    final good = encodeOp(op);
    final bad = <Object?>[
      null,
      [good],
      {...good, 'op_id': 'no-seq'},
      {...good, 'op_id': 'other:1'}, // op id device must match the clock's node
      {...good, 'record': 'no-type'},
      {...good, 'kind': 'explode'},
      {...good, 'kind': 'inc', 'by': 1.5},
      {...good, 'kind': 'add', 'element': <Object?>[]},
      {...good, 'kind': 'add', 'element': double.nan},
      {...good, 'deps': 'a:1'},
      {
        ...good,
        'deps': [1],
      },
      {...good, 'hlc': 'garbage'},
      {...good}..remove('value'),
    ];
    for (final b in bad) {
      expect(() => decodeOp(b), throwsA(isA<AccordException>()), reason: '$b');
    }
  });
}
