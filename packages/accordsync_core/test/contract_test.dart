import 'dart:convert';
import 'dart:io';

import 'package:accordsync_core/accordsync_core.dart';
import 'package:test/test.dart';

/// The shared contract (golden vectors, protocol schemas), committed in `contract/` at the
/// workspace root. F1 makes the core pass every vector; for now, check the contract is there.
Directory contractDir() {
  var dir = Directory.current;
  while (!Directory('${dir.path}/contract').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) throw StateError('contract/ not found');
    dir = parent;
  }
  return Directory('${dir.path}/contract');
}

void main() {
  test('speaks protocol version 1, like the TypeScript packages', () {
    expect(protocolVersion, 1);
  });

  test('the golden vectors are present and readable', () {
    final vectors =
        Directory('${contractDir().path}/vectors')
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.json'))
            .map((f) => f.uri.pathSegments.last)
            .toList()
          ..sort();
    expect(vectors, ['conflict.json', 'counter.json', 'lww.json', 'set.json']);
    for (final name in vectors) {
      final json =
          jsonDecode(File('${contractDir().path}/vectors/$name').readAsStringSync())
              as Map<String, Object?>;
      expect(json['version'], 1, reason: name);
      expect(json['cases'], isA<List<Object?>>(), reason: name);
    }
  });

  test('the protocol schemas are present', () {
    for (final name in ['WireOp', 'PushRequest', 'PushResponse', 'PullItem', 'PullResponse']) {
      expect(
        File('${contractDir().path}/protocol/v1/$name.schema.json').existsSync(),
        isTrue,
        reason: name,
      );
    }
  });
}
