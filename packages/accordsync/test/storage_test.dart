import 'package:accordsync/accordsync.dart';
import 'package:accordsync_testing/storage_contract.dart';

void main() {
  storageContract('memory', () => (store: MemoryStorage(), reopen: null));
}
