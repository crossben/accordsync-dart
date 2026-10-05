# Accord for Dart and Flutter

**Offline-first sync that stays correct when the network lies**, for Dart and Flutter apps.

Apps keep working with no connection. When it comes back, every device ends up with the same data:
changes merge by rules you declare per field, counters never lose an increment, and conflicting
decisions are kept for your app to settle instead of being guessed.

These packages speak the same protocol and merge by the same rules as the
[TypeScript packages](https://github.com/crossben/accordsync), so Flutter and web or React Native
devices sync through the same server.

> **Status: in development.** Not published on pub.dev yet. Website and docs:
> [accord.benhattab.pro](https://accord.benhattab.pro).

## Packages

| Package | What it does |
| --- | --- |
| `accordsync_core` | The merge core: hybrid logical clocks, operations, `lww`, `counter`, `set` and `conflict`. Pure Dart. |
| `accordsync` | The client: local-first writes, background sync, conflicts and refusals. Pure Dart, works in Flutter, CLI tools and servers. |
| `accordsync_flutter` | Storage on the device (drift), widgets for records, conflicts and sync status, and sync that follows the app lifecycle. |

## Develop

Requires Flutter 3.44+ (Dart 3.12+).

```sh
flutter pub get
dart format --output=none --set-exit-if-changed .
flutter analyze
(cd packages/accordsync_core && dart test)
(cd packages/accordsync && dart test)
(cd packages/accordsync_flutter && flutter test)
```

`contract/` holds the golden vectors and protocol schemas from the Accord repository; every Dart
implementation must pass them. Refresh it with `dart run tool/sync_contract.dart` (reads `../app`,
or `ACCORD_APP_DIR`).

## Licence

[Apache-2.0](LICENSE).
