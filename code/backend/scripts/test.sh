#!/usr/bin/env bash
# Run all integration tests and stop on the first failure.
# Usage: ./scripts/test.sh [extra mix test flags]
#
# Each test file is run in its own `mix test` call so that a failure in one
# file stops the entire run immediately (--fail-fast only works within a
# single invocation; across files we need the per-call exit-code check).

set -euo pipefail

cd "$(dirname "$0")/.."

TESTS=(
  test/itgr_db_persistence.exs
  test/itgr_master_buffer.exs
  test/itgr_context_engine.exs
  test/itgr_crash_recovery.exs
  test/itgr_worker_loop.exs
  test/itgr_confidant_flow.exs
  test/itgr_compaction.exs
)

EXTRA_FLAGS=("$@")

echo "==> Running integration tests"
echo

for f in "${TESTS[@]}"; do
  echo "--- $f"
  MIX_ENV=test mix test --max-failures 1 "${EXTRA_FLAGS[@]}" "$f"
  echo
done

echo "==> All tests passed."
