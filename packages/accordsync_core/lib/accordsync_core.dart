/// The Accord merge core: hybrid logical clocks, ops, the `lww`, `counter`, `set` and `conflict`
/// strategies, and the replica. Pure Dart, no I/O; merges byte-for-byte like `@accordsync/core`.
library;

export 'src/canonical.dart';
export 'src/errors.dart';
export 'src/hlc.dart';
export 'src/op.dart';
export 'src/protocol.dart';
export 'src/replica.dart';
export 'src/schema.dart';
export 'src/strategies.dart';
export 'src/wire.dart';
export 'src/writer.dart';
