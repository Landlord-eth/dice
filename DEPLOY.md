# Deploying LANDLORD (operator runbook)

Nothing here has been run against Robinhood Chain. The hook is immutable: no owner, no upgrade key,
no pause. A fix means a new hook and LPs moving to it. An external audit before real money is the
operator's call; this lane's own review is in SECURITY.md and CORE.md.

## Before
1. The LANDLORD token exists (its address is a constructor constant; the hook cannot be pointed at a
   different token later).
2. A plain Uniswap v4 pool LANDLORD/USDG exists and holds liquidity on PoolManager
   `0x8366a39CC670B4001A1121B8F6A443A643e40951`: no hook, static fee of at least 0.3% (3000), any
   tick spacing. The crank buys here; it spends at most 0.1% of the pool's in-range USDG per call, so
   the burn rate scales with this pool's depth. **Needs operator money.**
3. A deployer key with a little ETH on Robinhood Chain. Check the cost at the time:
   `cast gas-price -r https://rpc.mainnet.chain.robinhood.com` (the hook's init code is 21.6 KB).
4. `scripts/test.sh fresh` passes on the final code (it pins the latest block).

## Deploy and open the first pool
```
export PATH="$HOME/.foundry/bin:$PATH"
BURN_TOKEN=<LANDLORD token> \
BURN_POOL_FEE=3000 BURN_POOL_TICK_SPACING=60 \
OPEN_TOKENS=0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa \
OPEN_REF_POOLS=0x1f5bf0b4df6d26da68a30535727acaf41634443b6421bcecd8ac1d455b2f91d6 \
forge script script/Deploy.s.sol --tc Deploy \
  --rpc-url https://rpc.mainnet.chain.robinhood.com --skip-simulation --broadcast --account <keystore>
```
- `--skip-simulation` is required: forge's pre-broadcast simulation has no Arbitrum precompiles, and the
  hook reads the chain's block number from ArbSys (`0x64`). The script stands in for ArbSys only inside
  forge's own run; the broadcast transactions execute against the real one.
- The script also deploys `SeatDeskFactory(PoolManager, hook)`, the factory every wallet opens its
  seat desk from (a seat held by a plain wallet could not swap fee-free). It logs `desk factory`.
- The script mines a CREATE2 salt so the address carries the hook's permission bits, deploys through the
  deterministic deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C` (present on the chain), then
  initializes each `OPEN_TOKENS[i]`/USDG pool at the current price of `OPEN_REF_POOLS[i]` (a v4 pool of
  the same pair). The example opens SPCX/USDG at the price of the busiest SPCX/USDG pool.
- NVDA has no USDG v4 pool to copy a price from; opening NVDA needs a price the operator supplies.

## After
1. `cast call <hook> "deploymentBlockNumber()(uint256)"` is the chain's block (about 91 million in
   October 2026), not an Ethereum block (about 26 million). If it is the small number, stop: the clock is wrong.
2. `cast call <hook> "currentFee(bytes32)(uint24)" <poolId>` returns 3000.
3. Seed the first LANDLORD pool with `addLiquidity` (operator money; the replay used about $980k a side).
4. Verify the source on Sourcify (Blockscout sits behind Cloudflare for scripts).
5. Give the product and web lanes the hook address, the desk factory address
   (`NEXT_PUBLIC_LANDLORD_DESKS`), the pool ids and the deployment block.
