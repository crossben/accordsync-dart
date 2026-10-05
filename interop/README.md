# Interop tests

Dart and TypeScript Accord clients against the real server.

- `test/http_test.dart`: the Dart client over HTTP against `@accordsync/server`: refusals,
  scope exits and deltas, compaction snapshots, `device_seq`, HTTP errors.
- `test/mixed_fleet_test.dart`: Dart devices and TypeScript devices (`@accordsync/client`, driven
  by `node/ts-client.mjs`) edit the same records through a network that loses requests and
  responses, with a compaction mid-run. After the network heals, every device must hold
  byte-identical canonical snapshots.

The server and TypeScript client are the published npm packages, pinned in `node/package.json`.

```sh
interop/run.sh                               # needs Docker, Node 22+ and Dart
ACCORD_INTEROP_SEEDS=1,2,3,4,5 interop/run.sh
```

`node/server.mjs` also listens on a second port (8788) for test-only routes: sign a token, reset the
database, run compaction. It exists for these tests only.
