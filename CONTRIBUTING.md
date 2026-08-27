# Contributing

LANDLORD is a Uniswap v4 hook for Robinhood Chain stock pools. The auction is a port of Bunni's
BidDog, so changes to `src/AmAmm.sol` should stay a faithful port unless an issue explains why not.

## Running the suite

```
forge build
forge test --match-path test/AmAmm.t.sol     # auction properties, no network
scripts/test.sh                              # everything, replayed offline at the pinned Robinhood Chain block
scripts/test.sh fresh                        # pin the latest block (reads the public RPC once)
```

The fork tests under `test/fork/` read Robinhood Chain state through `state/rpc-cache.json`. If you
change anything under `src/`, run `scripts/test.sh fresh` and commit the new `state/` files with your
change.

## Pull requests

- One change per pull request, with the test that shows it.
- `forge fmt` on `src/` and `script/`.
- Every number in `CORE.md` that your change moves gets updated in the same pull request.
- No admin keys, no pause, no upgrade path. A change that needs one is a different protocol.
