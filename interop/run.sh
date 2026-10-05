#!/usr/bin/env bash
# Runs the interop tests: PostgreSQL in Docker, the real Accord server from npm, then `dart test`.
#   interop/run.sh                       (from the repository root or interop/)
#   ACCORD_INTEROP_SEEDS=1,2,3,4,5 interop/run.sh
# Set ACCORD_DATABASE_URL to use a PostgreSQL that is already running (CI does).
set -euo pipefail
cd "$(dirname "$0")"

if [[ -z "${ACCORD_DATABASE_URL:-}" ]]; then
  docker compose up -d --wait
  export ACCORD_DATABASE_URL=postgres://accord:accord@localhost:55432/accord
  trap 'docker compose down >/dev/null 2>&1' EXIT
fi

(cd node && npm ci --no-audit --no-fund)
node node/server.mjs &
server=$!
trap 'kill $server 2>/dev/null; docker compose down >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 60); do curl -sf http://localhost:8787/health >/dev/null && break; sleep 0.5; done

dart test
