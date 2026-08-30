![LANDLORD](.github/banner.webp)

# LANDLORD engine

An am-AMM ("am-AMM: An Auction-Managed Automated Market Maker", Adams, Moallemi, Reynolds, Robinson,
arXiv 2403.03367) as a Uniswap v4 hook for Robinhood Chain stock pools. The seat auction is a port of
Bunni's BidDog. Designed by researchers from Columbia, Paradigm and Uniswap Labs; we built the hook.

- `src/AmAmm.sol`: the seat auction (bid, queue, K-block delay, rent per block, refunds, fees).
- `src/Landlord.sol`: the hook. Holds each pool's only full-range position, books LP shares, takes the
  swap fee for the seat holder (or the LPs when nobody holds it), pays rent to LPs, burns 4% of rent.
- `src/SeatDesk.sol`: the contract a wallet holds a seat with (fee-free swaps, seat calls), and its factory.
- `script/Deploy.s.sol`, `script/HookAddress.sol`: deployment (see DEPLOY.md).
- `test/`: auction properties, fork tests on the real PoolManager with SPCX and USDG, invariants, and
  the replay of a real SPCX session (`research/`).

```
scripts/test.sh          # replay the pinned Robinhood Chain block from the saved fork cache
scripts/test.sh fresh    # pin the latest block (needed after changing src/), read it once, save the cache
```

CORE.md is the contract for the app and site: parameters, interface, every number with its unit, and
the measured comparison. SECURITY.md is the threat model.

## Tests

`forge test --match-path test/AmAmm.t.sol` needs no network. The fork tests under `test/fork/` replay a
pinned Robinhood Chain block from `state/rpc-cache.json` through `scripts/test.sh`; CI runs only the
network-free part.

## License

AGPL-3.0, like BidDog. Copyright (c) 2026 LANDLORD.
