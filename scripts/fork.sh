#!/usr/bin/env bash
# Local Robinhood Chain fork for the test suite.
#   scripts/fork.sh live      fork the public RPC at its latest block (state is only served for ~10 min)
#   scripts/fork.sh down      stop the node this script started (by its PID file)
# A fresh test run forks this node, so every slot is read from the public RPC once, with retries.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"
PORT="${LANDLORD_FORK_PORT:-48470}"
URL="http://127.0.0.1:$PORT"
mkdir -p logs state

free_port() {
  if lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "port $PORT is in use by another process; set LANDLORD_FORK_PORT" >&2
    exit 1
  fi
}

wait_up() {
  for _ in $(seq 1 60); do
    cast chain-id -r "$URL" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  echo "node did not start, see logs/anvil.log" >&2
  exit 1
}

case "${1:-}" in
  live)
    free_port
    nohup anvil --fork-url https://rpc.mainnet.chain.robinhood.com --port "$PORT" --chain-id 4663 \
      --hardfork cancun --retries 20 --fork-retry-backoff 2000 --timeout 60000 \
      --compute-units-per-second 330 > logs/anvil.log 2>&1 &
    echo $! > logs/anvil.pid
    wait_up
    echo "fork of block $(cast block-number -r "$URL") on $URL, pid $(cat logs/anvil.pid)"
    ;;
  down)
    [ -f logs/anvil.pid ] && kill "$(cat logs/anvil.pid)" 2>/dev/null || true
    rm -f logs/anvil.pid
    ;;
  *)
    echo "usage: $0 live|down" >&2
    exit 2
    ;;
esac
