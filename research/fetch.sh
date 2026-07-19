#!/usr/bin/env bash
# Real swaps of the busiest SPCX/USDG Uniswap v4 pool on Robinhood Chain over one NASDAQ session
# (Friday 2026-10-16, 12:45 to 20:13 UTC, L2 blocks 90,088,000 to 90,330,980: the regular session plus the 45 minutes before the open). Read-only log query.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$HOME/.foundry/bin:$PATH"
R=https://rpc.mainnet.chain.robinhood.com
PM=0x8366a39cc670b4001a1121b8f6a443a643e40951
POOL=0x1f5bf0b4df6d26da68a30535727acaf41634443b6421bcecd8ac1d455b2f91d6
SWAP=$(cast keccak "Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")
FROM=90088000
TO=90330980
mkdir -p data
: > data/spcx_swaps.jsonl
s=$FROM
while [ "$s" -le "$TO" ]; do
  e=$((s + 49999)); [ "$e" -gt "$TO" ] && e=$TO
  cast rpc -r "$R" eth_getLogs "{\"address\":\"$PM\",\"fromBlock\":\"$(printf 0x%x "$s")\",\"toBlock\":\"$(printf 0x%x "$e")\",\"topics\":[\"$SWAP\",\"$POOL\"]}" >> data/spcx_swaps.jsonl
  echo >> data/spcx_swaps.jsonl
  s=$((e + 1))
  sleep 0.3
done
cast block "$FROM" -r "$R" -f timestamp > data/window.txt
cast block "$TO" -r "$R" -f timestamp >> data/window.txt
wc -l data/spcx_swaps.jsonl
