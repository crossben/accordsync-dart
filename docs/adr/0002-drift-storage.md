# ADR-F02: Drift for storage on Flutter devices

- Status: accepted
- Date: 2026-10-05

## Decision

`accordsync_flutter` stores the device's ops, outbox, snapshots and metadata with **drift**, in the
same table layout as the TypeScript SQLite adapter (`accord_ops`, `accord_outbox`,
`accord_snapshots`, `accord_meta`).

The storage interface itself (`load()` and an atomic `commit(tx)`) lives in `accordsync`, so other
adapters (sqflite, Isar, in-memory) can be written without touching the client.

## Why

- Drift is typed, well maintained, runs SQLite on every Flutter platform, and supports
  transactions, which an atomic commit requires.
- The owner's Flutter apps (Komizi) already use drift: one storage stack to know and to debug.
- The same table layout as the TypeScript adapter keeps the two implementations easy to compare.
