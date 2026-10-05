# accordsync_flutter

**Offline-first sync for Flutter apps that stays correct when the network lies.**

Your app writes to the phone first and keeps working with no connection. When the network comes
back, every device ends up with the same data: each field merges by the rule you declare, counters
never lose an increment, and two different decisions made offline are kept for a person to settle
instead of being guessed.

This package adds the Flutter parts to [`accordsync`](https://pub.dev/packages/accordsync): storage
on the device with drift, widgets, and sync that follows the app lifecycle. It syncs with the
[Accord server](https://accord.benhattab.pro/docs/server/), alongside web and React Native devices
using the TypeScript packages.

## Install

```sh
flutter pub add accordsync_flutter drift_flutter
```

## Use

```dart
import 'package:accordsync_flutter/accordsync_flutter.dart';
import 'package:drift_flutter/drift_flutter.dart';

// The same schema as your server.
final schema = defineSchema({
  'dossier': {
    'client_name': lww(), // highest clock wins
    'visits': counter(), // every increment counts
    'docs': set(), // add-wins set
    'status': conflict(), // concurrent decisions are kept for a person to settle
  },
});

final accord = await AccordClient.open(
  schema: schema,
  storage: DriftStorage(AccordDatabase(driftDatabase(name: 'accord')), closeDatabase: true),
  transport: HttpTransport(url: 'https://sync.example.com', getToken: auth.currentToken),
);

runApp(
  AccordProvider(
    client: accord,
    child: AccordLifecycle(client: accord, child: const MyApp()),
  ),
);
```

Read a record, and rebuild when it changes on this device or arrives from the server:

```dart
RecordBuilder(
  record: 'dossier:91',
  builder: (context, fields) => Text('${fields?['visits'] ?? 0} visits'),
)
```

Write: the call completes as soon as the change is saved on the phone, online or not.

```dart
await accord.inc('dossier:91', 'visits', 1);
await accord.add('dossier:91', 'docs', 'id-card.pdf');
```

Show conflicts where someone can decide, and resolve one:

```dart
ConflictsBuilder(
  builder: (context, conflicts) => Column(children: [
    for (final c in conflicts)
      for (final v in c.values)
        TextButton(
          onPressed: () => accord.resolve(c.record, c.field, v.value),
          child: Text('Keep ${v.value}'),
        ),
  ]),
)
```

## What's inside

| | |
| --- | --- |
| `DriftStorage` | Stores ops, the outbox and snapshots in SQLite through drift. Pass your app's own database (Accord adds four tables prefixed `accord_`), or `AccordDatabase` for a separate file. No code generation. |
| `AccordProvider` | Makes the client available below it (`AccordProvider.of(context)`). |
| `RecordBuilder` | Rebuilds when one record changes. |
| `ConflictsBuilder` | Every `conflict()` field holding more than one value. |
| `SyncStatusBuilder` | Pending writes, last sync, last error. |
| `AccordLifecycle` | Syncs in the foreground, pauses in the background, syncs when `online` emits `true` (feed it from `connectivity_plus` or similar). |

Everything from `accordsync` and `accordsync_core` is re-exported.

The device database is not encrypted by Accord. Protect it like the rest of your app's data.

## Learn more

- Docs: [accord.benhattab.pro/docs](https://accord.benhattab.pro/docs/)
- A two-agent demo app: [`example/field_app`](https://github.com/crossben/accordsync-dart/tree/main/example/field_app)
- Source: [crossben/accordsync-dart](https://github.com/crossben/accordsync-dart)
