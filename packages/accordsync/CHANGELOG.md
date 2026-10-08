## Unreleased

- Fixed: a write made while a sync round was in flight waited for the next `syncInterval` (30 s by
  default) instead of syncing about 50 ms after the round.

## 0.3.0

- Version aligned with the TypeScript, PHP and Python packages 0.3.0: same protocol v1, same merge
  rules. Checked against the 0.3.0 contract: the golden and random vectors, including a new case
  for UTF-16 set-element order.
- Works with `@accordsync/server` 0.3.0, which adds two migrations and server-side fixes; no client
  change is needed.

## 0.2.0

- First release. Speaks Accord protocol v1 and merges like the TypeScript packages 0.2.x.
