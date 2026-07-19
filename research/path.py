"""Turn the fetched SPCX/USDG swaps into the price paths the fork replay reads.

block path:  the pool price after the last swap of every block that had one (the price a new
             venue sees on Robinhood Chain, including bounces from uninformed trades)
minute path: the last price of every 600-block (one minute) bucket that had a swap
Prices are Uniswap sqrtPriceX96 of SPCX (token0, 18 decimals) in USDG (token1, 6 decimals).
"""
import json
import statistics
import sys
from pathlib import Path

D = Path(__file__).parent / "data"
FROM = 90088000
swaps = []
for line in open(D / "spcx_swaps.jsonl"):
    line = line.strip()
    if not line.startswith("["):
        continue
    for log in json.loads(line):
        w = [int(log["data"][2 + i : 2 + i + 64], 16) for i in range(0, len(log["data"]) - 2, 64)]
        s = lambda x: x - (1 << 256) if x >= 1 << 255 else x
        swaps.append(
            dict(block=int(log["blockNumber"], 16), idx=int(log["logIndex"], 16), a0=s(w[0]), a1=s(w[1]), sqrt=w[2], liq=w[3], fee=w[5])
        )
swaps.sort(key=lambda x: (x["block"], x["idx"]))

def price(sq):
    return (sq / 2**96) ** 2 * 1e12  # USDG per SPCX

last = {}
for x in swaps:
    last[x["block"]] = x["sqrt"]
blocks = sorted(last)
minute = {}
for b in blocks:
    minute[(b - FROM) // 600] = (b, last[b])

def dump(name, pts):
    json.dump({"blocks": [b - FROM for b, _ in pts], "sqrtPrices": [str(p) for _, p in pts]}, open(D / name, "w"))

dump("spcx_path_block.json", [(b, last[b]) for b in blocks])
dump("spcx_path_minute.json", sorted(minute.values()))

vol = sum(abs(x["a1"]) for x in swaps) / 1e6
moves = [abs(price(last[b]) / price(last[a]) - 1) for a, b in zip(blocks, blocks[1:])]
mmoves = [abs(price(q[1]) / price(p[1]) - 1) for p, q in zip(sorted(minute.values()), sorted(minute.values())[1:])]
fees = [x["fee"] for x in swaps]
stats = dict(
    swaps=len(swaps),
    blocks_with_swaps=len(blocks),
    minutes_with_swaps=len(minute),
    volume_usdg=round(vol),
    first_price=round(price(swaps[0]["sqrt"]), 4),
    last_price=round(price(swaps[-1]["sqrt"]), 4),
    min_price=round(min(price(x["sqrt"]) for x in swaps), 4),
    max_price=round(max(price(x["sqrt"]) for x in swaps), 4),
    move_per_block_median_pct=round(statistics.median(moves) * 100, 4),
    move_per_block_p99_pct=round(sorted(moves)[int(len(moves) * 0.99)] * 100, 4),
    move_per_minute_median_pct=round(statistics.median(mmoves) * 100, 4),
    ref_pool_fee_median_pips=statistics.median(fees),
    ref_pool_fee_p10_p90_pips=[sorted(fees)[len(fees) // 10], sorted(fees)[len(fees) * 9 // 10]],
    ref_pool_liquidity_median=statistics.median(x["liq"] for x in swaps),
)
json.dump(stats, open(D / "spcx_stats.json", "w"), indent=1)
json.dump(stats, sys.stdout, indent=1)
