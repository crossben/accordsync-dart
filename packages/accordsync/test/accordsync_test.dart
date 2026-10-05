import 'package:accordsync/accordsync.dart';
import 'package:test/test.dart';

void main() {
  test('re-exports the protocol version of the core', () {
    expect(protocolVersion, 1);
  });
}
