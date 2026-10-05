# accordsync

**The Accord client for Dart: local-first writes, background sync, conflicts and refusals.**

Writes apply on the device at once and are saved; sync pushes them to the
[Accord server](https://accord.benhattab.pro/docs/server/) and pulls everyone else's. Each field
merges by the rule you declare, so every device converges on the same data whatever order changes
arrive in.

Pure Dart: works in Flutter (use [`accordsync_flutter`](https://pub.dev/packages/accordsync_flutter)
for storage on the device and widgets), command-line tools and servers. It speaks the same protocol
as the TypeScript client, so Dart and JavaScript devices sync together.

## Use

```dart
import 'package:accordsync/accordsync.dart';

final schema = defineSchema({
  'dossier': {'client_name': lww(), 'visits': counter(), 'docs': set(), 'status': conflict()},
});

final accord = await AccordClient.open(
  schema: schema,
  storage: MemoryStorage(), // or DriftStorage from accordsync_flutter
  transport: HttpTransport(url: 'https://sync.example.com', getToken: () => token),
);

await accord.inc('dossier:91', 'visits', 1); // saved locally, synced later
accord.start(); // sync after writes, every 30 s, with backoff while offline

accord.refusals.listen((r) => print('the server refused ${r.field}: ${r.reason}'));
print(accord.read('dossier:91'));
print(accord.conflicts());
```

## What's inside

- `AccordClient`: `open`, `assign`, `inc`, `add`, `remove`, `resolve`, `read`, `records`,
  `conflicts`, `status`, `sync`, `start`/`stop`, `close`, and the streams `changes`, `refusals`,
  `synced`, `resyncs` and `errors`.
- `StorageAdapter` (atomic `load`/`commit`) and `MemoryStorage`.
- `Transport` and `HttpTransport`.

A write the server refuses (out of the user's scope, for example) is rolled back on the device and
reported on `refusals`: never kept silently, never lost silently.

Docs: [accord.benhattab.pro/docs](https://accord.benhattab.pro/docs/) ·
Source: [crossben/accordsync-dart](https://github.com/crossben/accordsync-dart)
