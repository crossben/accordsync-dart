import 'dart:io';

/// The shared contract (golden vectors, protocol schemas), committed in `contract/` at the
/// workspace root.
Directory contractDir() {
  var dir = Directory.current;
  while (!Directory('${dir.path}/contract').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) throw StateError('contract/ not found');
    dir = parent;
  }
  return Directory('${dir.path}/contract');
}
