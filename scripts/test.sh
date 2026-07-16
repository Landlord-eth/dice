#!/usr/bin/env bash
# Runs the whole suite on a fork of Robinhood Chain.
#   scripts/test.sh          replay at the pinned block in state/FORK_BLOCK from the saved fork cache
#   scripts/test.sh fresh    pin the latest block, read it through a local anvil, save the cache
# The public RPC serves state for only ~10 minutes, so a fresh run must finish inside that window;
# every later run replays the same block from state/rpc-cache.json with no state reads at all.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"
mkdir -p logs state
CACHE_DIR="$HOME/.foundry/cache/rpc/4663"
EXTRA=("${@:2}" --no-match-test __none__)

if [ "${1:-}" = "fresh" ]; then
  scripts/fork.sh live
  trap 'scripts/fork.sh down' EXIT
  BLOCK=$(cast block-number -r "http://127.0.0.1:${LANDLORD_FORK_PORT:-48470}")
  echo "$BLOCK" > state/FORK_BLOCK
  # the fuzzers first, while the block's state is still served; then the rest
  FORK_BLOCK=$BLOCK FORK_URL="http://127.0.0.1:${LANDLORD_FORK_PORT:-48470}" forge test --match-contract Solvency "${EXTRA[@]}" > logs/test-warm.log 2>&1 || true
  FORK_BLOCK=$BLOCK FORK_URL="http://127.0.0.1:${LANDLORD_FORK_PORT:-48470}" forge test "${EXTRA[@]}" > logs/test.log 2>&1 || true
  cp "$CACHE_DIR/$BLOCK" state/rpc-cache.json
else
  BLOCK=$(cat state/FORK_BLOCK)
  mkdir -p "$CACHE_DIR"
  [ -f "$CACHE_DIR/$BLOCK" ] || cp state/rpc-cache.json "$CACHE_DIR/$BLOCK"
  FORK_BLOCK=$BLOCK FORK_URL=hood forge test "${EXTRA[@]}" > logs/test.log 2>&1 || true
fi

grep -E "^Suite result|^Ran [0-9]+ test suites" logs/test.log
grep -E "^\[FAIL" logs/test.log | head -20 || true
grep -q "0 failed" <(grep "^Ran" logs/test.log) && echo "block $BLOCK: all passed"
