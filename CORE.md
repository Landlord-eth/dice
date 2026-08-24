# LANDLORD engine: core

The contract for the product and web lanes. Solidity 0.8.26, Foundry, Uniswap v4 hook on Robinhood
Chain (chainId 4663) on the real PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951`.
Sources: `src/AmAmm.sol` (seat auction), `src/Landlord.sol` (hook), `src/SeatDesk.sol` (the contract a
wallet holds a seat with, and its factory). License AGPL-3.0 (the auction is
a port of BidDog, which is AGPL-3.0). Not deployed anywhere.

Source: "am-AMM: An Auction-Managed Automated Market Maker", Austin Adams (Whetstone Research),
Ciamac C. Moallemi (Columbia, Paradigm), Sara Reynolds (Uniswap Labs), Dan Robinson (Paradigm),
arXiv 2403.03367. Auction state machine from Bunni's BidDog (github.com/Bunniapp/biddog).
Copy line: "designed by researchers from Columbia, Paradigm and Uniswap Labs". We did not invent it.

## What it does
One LANDLORD pool per token, always paired with USDG, on the real v4 PoolManager. The hook is the
pool's only liquidity provider: it holds one full-range position and keeps each LP's share in its own
books, so every unit of liquidity earns the same rent (the paper's constant-product setting).
- A bid names a rent per block (USDG), a swap fee (at most 1%) and a deposit of at least K blocks of
  rent. It can take the seat K blocks after it lands, if it beats the holder's rent by more than 10%;
  otherwise it waits until the holder's deposit runs out. The replaced holder gets the rest of its
  deposit back; an outbid queued bid gets all of it back. Bids cannot be cancelled.
- The seat holder pays rent every block from its deposit: 96% to LPs by liquidity and time, 4% kept
  to buy and burn the LANDLORD token. It keeps every swap fee, swaps fee-free from the contract that
  holds the bid, and can change the fee from the next block on.
- No seat holder: the fee is 0.3% and goes to the LPs. A normal pool.
- LPs who leave while a seat is held pay 13 ppm (0.0013%) to the holder (paper, appendix B).

## Parameters and why
| Parameter | Value | Why |
|---|---|---|
| Block clock | `ArbSys(0x64).arbBlockNumber()` | On Robinhood Chain `block.number` is the Ethereum block (measured 26,212,905 while the chain was at 91,001,176). Everything below counts the chain's own blocks: 242,626 blocks in 24,494 s in the replay window, 0.101 s each. BidDog does the same on Arbitrum One. |
| Delay K | 7,200 blocks, about 12 minutes | BidDog's number, unchanged. Long enough that nobody can grab the seat for a move they already see (a NASDAQ print, the open), short enough that the rent follows the trading day. It does not make the auction censorship resistant against Robinhood's own sequencer: the chain's force-inclusion window is about 24 hours, and a K that long would freeze the rent for a whole day. Stated, not solved. |
| Raise | more than 10% | BidDog's `MIN_BID_MULTIPLIER`. Each queue reset raises the rent LPs will be paid by over 10%. |
| Deposit | at least K blocks of rent, a multiple of rent, never withdrawn below K blocks | Paper: `D >= R * K`. A holder can never stop paying sooner than 12 minutes from now. |
| Fee cap | 1% | Paper's example cap; the top fee tier of existing SPCX/USDG v4 pools. |
| Default fee | 0.3% | The median fee paid on the busiest SPCX/USDG v4 pool in the replay window (3,000 pips). |
| Fee change | from the next block | Paper: "adjust the swap fee for the next block". |
| Withdrawal fee | 13 ppm while a seat is held | Paper appendix B: `1 - 2 sqrt(1 + c) / (2 + c)` = 12.38 ppm at c = 1%, rounded up. |
| Reserve rent | 1% a year of pool value (2 x USDG side at the current price) | Below what arbitrage alone paid a seat in the replay (2.5% a year at 0.3%, 252 sessions), so an active stock pool can seat a bidder; above zero so a dead pool is not handed out for nothing. 39 units (0.000039 USDG) a block on a $1.2M pool. |
| Burn share | 4% of rent | Comes entirely out of LP rent. The largest share at which a fully competed seat left LPs ahead of both plain v4 and a 45% rebate at the default fee in the replay (break-even 4.5%; see below). |
| Burn crank | once per block, at most 0.1% of the burn pool's in-range USDG depth, 2% price limit; burn pool must be a plain v4 pool with a fee of at least 0.3% | To overcharge the crank by p, an attacker must move the burn pool by p, which costs the 0.3% fee on twice the push; at 0.1% of depth per crank that costs more than the overpayment. Tested. |
| Tick spacing | 60, full range | One key per pair (E2); full range because the paper's result needs equal rent per unit of liquidity. |

## Interface (all amounts in raw token units; USDG has 6 decimals, stock tokens 18)
- `addLiquidity(key, liquidity, amount0Max, amount1Max, sqrtPriceMinX96, sqrtPriceMaxX96)`,
  `removeLiquidity(key, liquidity, amount0Min, amount1Min, sqrtPriceMinX96, sqrtPriceMaxX96)`,
  `collect(key, recipient)` (rent and no-seat fees), `owed(key, owner)` (view, includes rent not yet charged).
  LPs approve the hook for both tokens. Liquidity is v4 liquidity of a full-range position.
- `bid(id, manager, fee, rent, deposit)`: deposit pulled from the caller; `manager` owns the bid and is
  the address whose swaps are fee-free (the contract that calls `PoolManager.swap`).
- `depositIntoBid(id, amount, isTop)`, `withdrawFromBid(id, amount, recipient, isTop)`,
  `setBidFee(id, fee, isTop)`, `claimRefund(id, recipient)`, `claimFees(currency, recipient)`.
- Views: `getBid(id, isTop)` (settled to this block), `minRent(id)`, `currentFee(id)`,
  `getRefund(manager, id)`, `getFees(manager, currency)`, `deploymentBlockNumber()`, `pools(id)`,
  `positions(id, owner)`, `burnBucket()`, `totalBurnSpent()`, `totalBurned()`, `burnPoolKey()`.
- `crankBurn()` (anyone), `updateStateMachine(id)` (anyone).
- Swaps go through any v4 router; the fee is taken from the unspecified side (the output of an
  exact-in swap). Errors: one custom error per failure in `src/AmAmm.sol`, `src/Landlord.sol`, `src/SeatDesk.sol`.
- **Robinhood Chain's Universal Router** (`0x8876…0904`, found by the product lane) is a recent
  v4-periphery build: its v4 `ExactInputSingleParams` has a `minHopPriceX36` field before `hookData`.
  The older encoding without it only happens to work on pools whose currency0 is native ETH and
  reverts with no data on USDG pools. Every LANDLORD pool is a USDG pool: encode the new struct
  (`web/app/app/lib/landlord.ts routerSwap`).

## Holding a seat from a wallet: SeatDesk
The fee is waived only when the PoolManager's caller is the seat holder. A wallet cannot be that
caller (it needs an unlock callback) and a router makes itself the caller. So a wallet holds its seat
through a desk: `SeatDeskFactory.open()` creates one per wallet (CREATE2, salt = the wallet, so the app
can compute the address first; nobody can open a desk for someone else). The wallet bids with
`manager = desk` (the hook pulls the deposit from the wallet), approves the desk for the tokens it
swaps, and then calls the desk:
- `swap(key, zeroForOne, amountIn, minOut)`: exact-in, fee-free, input pulled from the wallet and output
  paid to it inside one PoolManager callback. LANDLORD pools only.
- `setFee(id, fee, isTop)`, `topUp(id, amount, isTop)` (USDG from the wallet straight into the bid),
  `withdraw(id, amount, isTop)`, `claimRefund(id)`, `claimFees(currency)`: every payout names the wallet.
- Owner only, and only these calls. Changes from the product lane's draft: the owner-only `exec(target,
  data)` and the free-form `topUp(hook, quote, call, amount)` are gone. A desk the wallet has approved for
  its tokens must not be able to make any other call, or one bad signature (a hostile page asking for
  an `exec`) could move those tokens; the hook is now a constant of the desk instead of a parameter.
  Swaps are limited to pools of this hook and refuse to pay more than `amountIn`, because a pool with
  another hook could charge the swapper extra through a hook delta, paid from the wallet's approval.
- The factory is deployed with the hook (`script/Deploy.s.sol`); the app needs its address.

## Numbers the app and site may show (E6)
Never add SPCX and USDG amounts without converting at a stated price.
- **Seat rent**: `getBid(id, true).rent` USDG units per block. Per day: x 864,000 (0.1 s blocks), say "about".
- **Rent yield**: `rent x 315,360,000 / pool value`, % a year. Pool value in USDG = 2 x USDG side
  = `2 x L x sqrtPriceX96 / 2^96` when USDG is token1 (SPCX/USDG), `2 x L x 2^96 / sqrtPriceX96` when token0.
- **Rent to LPs**: 96% of rent. **Reserve rent**: `minRent(id)`.
- **Fee now**: `currentFee(id)` in pips (10,000 = 1%); the holder's own swaps pay 0.
- **Queued bid start**: block `deploymentBlockNumber() + next.blockIdx + 7,200` if `next.rent > 1.1 x top.rent`,
  else the block the holder runs dry: `deploymentBlockNumber() + top.blockIdx + top.deposit / top.rent`.
- **Runway**: `deposit / rent` blocks, x 0.1 s.
- **Your rent and fees**: `owed(key, lp)`, per token.
- **Burned**: `totalBurned()` LANDLORD units sent to 0xdEaD; spent `totalBurnSpent()` USDG units;
  waiting `burnBucket()` USDG units.
- **Holder earnings**: `getFees(manager, currency)` per token, unclaimed.
- **LANDLORD vs plain v4**: only the replay numbers below, labelled as one past session, never as a forecast.

## Measured on the fork: one real session of the busiest SPCX/USDG pool
`research/fetch.sh` reads (logs only) every swap of pool `0x1f5bf0b4…5f91d6` (SPCX/USDG, the most traded
stock/USDG v4 pool on Robinhood Chain) from 12:45 to 20:13 UTC on Friday 2026-10-16: 3,848 swaps,
$879,539 volume, SPCX $150.21 to $143.97 (-4.2%). `research/path.py` turns it into the price after the
last swap of every block that traded (3,454 points) and of every minute (367 points).
`test/fork/Replay.t.sol` then runs three full-range pools of equal size ($1.96M, about $980k a side)
on the real PoolManager through that price:
- **plain v4** at fee f; an outside arbitrageur trades it to the edge of the no-trade band each step;
- **45% rebate** (a What The Hook style model: its code is not public to us): same, and the arbitrageur
  donates 45% of its profit, marked at the market price, to the LPs;
- **LANDLORD** with a seat at fee f: outside arbitrageurs take the move beyond the band paying f to the
  holder, then the fee-free holder trades to the market price ("race", the paper's model), or the
  holder takes every move ("holder wins"). Pass 1 measures what the seat earns at the reserve rent;
  pass 2 bids rent = competition x earnings through a real bid and replays again.

LP result in USDG for the session, measured against a portfolio rebalanced at the market price (all
arbitrage profit, fees included, is the LP's loss; fees, rebates and rent the LP keeps are added back).
Arbitrage flow only:

| Price path, fee | plain v4 | 45% rebate | LANDLORD, full competition | LANDLORD, half competition | LANDLORD, holder wins all, full |
|---|---|---|---|---|---|
| every block, 0.05% | -98.75 | -54.31 | -92.29 | -143.76 | -7.98 |
| every block, 0.3% | -17.81 | -9.80 | **-8.87** | -102.27 | -7.98 |
| every block, 1% | -9.05 | **-4.98** | -7.98 | -101.84 | -7.98 |
| every minute, 0.3% | -95.90 | -52.74 | **-38.43** | -103.41 | -6.82 |

What the seat earned in the session (pass 1): $194 at 0.3% on the block path ($0.0008 a block,
about 2.5% a year of pool value over 252 sessions), $107 at 0.05% (the rest, $88, leaked to outside
arbitrageurs beyond the narrow band), $136 on the minute path.

What it says, plainly:
- **The amounts are small.** On a full-range SPCX pool the whole arbitrage in a -4.2% session was
  about $195 per $2M (0.01%). A plain 0.3% pool already keeps most of it as fees: its LPs lost $18.
  The large MOO losses (39-173% a month) were instant-price pools, not full-range v4 pools.
- **With competing bidders LANDLORD beat plain v4 in every case**, and beat the 45% rebate at 0.3%
  and on the minute path. It lost to the rebate at 1% ($8 vs $5) and on 0.05% with racing arbitrageurs.
- **With half competition LANDLORD was the worst in every case** (about -$100): LPs then lose the
  whole arbitrage and get half back. The product needs several bidders per seat. That is the real risk.
- **The burn share is paid by LPs.** At full competition LANDLORD's loss is the burn share of the
  seat's earnings plus the leak. The break-even burn share against the rebate is 4.5% at 0.3% and
  2.5% at 1%; against plain v4, 8.6% and 4.6%. We set 4%.
- **Uninformed flow is not replayed** (we cannot tell it apart in the real log). In plain v4 its fees go
  to LPs; in LANDLORD to the holder, then back as rent minus 4%. At the same 0.3% fee and full
  competition, LANDLORD stays ahead of plain v4 while uninformed volume is under about $74,500 per
  session per $2M of liquidity (block path; $479,000 on the minute path), unless the holder's lower
  fee draws more volume (the paper's other benefit, not modelled).
- Caveats: one pool, one session; the outside price is Robinhood Chain's own busiest pool, itself a
  late copy of NASDAQ, so true arbitrage against NASDAQ is larger than measured here for every
  design alike; rent in pass 2 is set at the session's realized earnings, while real bidders must
  guess it 12 minutes ahead; the 45% rebate is our model of What The Hook, not its code.
- Raw numbers per run: `research/out/replay_<path>_<fee>.json` (`*_flow` columns, plus results
  against holding the deposit, `*_lp`).

## Operator bar (engine)
- **E1. FIXED.** `concept.json` has no `judge.fixes`. Its `weaknesses_and_fixes`: (1) "What The Hook
  returns 45%: measure on a fork" is done above, with the result as measured, including where LANDLORD
  loses. (2) "Needs bidders; seat economics shown live": `getBid`, `minRent`, `currentFee`, `owed`
  and the `RentCharged`/`SwapFee` events give an agent everything to price a seat; the replay gives a
  first number (about $0.0008 a block for $2M of SPCX liquidity on a -4% day). (3) "Start with the
  most traded pools": SPCX/USDG is the busiest stock/USDG v4 pool (the replay pool). NVDA has no
  USDG v4 pool on Robinhood Chain (searched every v4 `Initialize` with NVDA: none), so an NVDA
  LANDLORD pool would open at a price the operator supplies; `script/Deploy.s.sol` opens pools only
  at the price of an existing v4 reference pool.
- **E2. PASS.** One pool per token: `beforeInitialize` accepts only `fee 0, tickSpacing 60,
  hooks = LANDLORD` with USDG on one side, so a pair has exactly one PoolId; a second initialize of the
  same key is refused by the PoolManager. Test `test_onlyTheCanonicalKeyInitializes` (fee 3000,
  spacing 10, a pair without USDG and the repeat all revert).
- **E3. PASS.** Unlike inputs at one price: LP deposits enter at the pool's own ratio (the PoolManager
  computes the amounts for the liquidity asked), rent and bids are USDG only, fees are booked per token.
  A token that delivers 2% less than it books cannot enter at all: the v4 settle sees 98 of 100 and the
  whole call reverts (`CurrencyNotSettled`), so no LP holds a short balance. Stock tokens pay dividends
  by raising a display multiplier; raw balances never change, so the pool sees no jump (memory fact,
  measured 2026-08). The one predictable jump is the ex-dividend drop of the 30% withheld tax: in
  LANDLORD that arbitrage goes to the seat holder and is priced into rent, in plain v4 it goes to
  whoever is fastest.
- **E4. PASS (stated plainly).** A LANDLORD SPCX/USDG pool starts as one more SPCX/USDG venue next to
  the existing v4 pools. Day one in and out: (a) it lives on the same PoolManager, so any v4 router can
  quote and route through it (whether Uniswap's own routing indexes a hooked pool is outside our
  control); (b) the seat holder keeps its price on the main pool's price every block, because fee-free
  arbitrage between the two is its income, so the pool is never a stale fragment while a seat is held;
  (c) with no holder it is a normal 0.3% pool that ordinary arbitrage keeps in line. Operator money:
  the first LP liquidity (the replay used about $980k a side; a seat is only worth bidding on a pool
  with real depth) and the LANDLORD/USDG plain v4 burn pool at launch.
- **E5. PASS (one side stated plainly).** LPs come for rent paid every block from a prepaid deposit
  (never below 1% a year while a seat is held) or a normal 0.3% pool when none is. Seat bidders (the
  chain's bots and agents) come for fee-free arbitrage against the other SPCX venues plus every swap
  fee: $107 to $195 per $2M per session in the replay, from arbitrage alone, with no retail flow at all.
  Swappers come through routers at the holder's fee. Plainly: LPs only beat plain v4 when bidders
  compete (half competition was the worst result in every row); the first bidders must exist before
  LPs see any benefit, and LPs carry the 4% burn share.
- **E5b. PASS.** 4% of all rent goes to `burnBucket`; `crankBurn` (anyone, no admin) buys the burn token
  on the plain LANDLORD/USDG v4 pool fixed at deploy and sends every unit to 0xdEaD. The token and pool
  are constructor constants (the token exists at launch, the hook is deployed after it). Tested on the
  fork with a stand-in ERC20 and a real plain v4 stand-in/USDG pool on the real PoolManager
  (`test_crankBuysAndBurns`, `test_crankSpendsAtMostTenthOfAPercentOfDepth`,
  `test_sandwichingTheCrankLosesMoney`). Worked example: a seat that rents for what it earns at the
  0.3% fee turns $1M of volume into $3,000 of fees, about $3,000 of rent, and **$120 of LANDLORD
  bought and burned**; arbitrage adds about $7.80 of burn per $2M of liquidity per session (4% of $195).
- **E6. PASS.** Every displayed number defined above with units; SPCX and USDG never summed.
- **Desk balance**: always 0 (tested after every desk action); a nonzero desk balance in the app means a bug.

## Every lane
- **P1. PASS.** Own anvil on 127.0.0.1:48470, checked free with `lsof` before each start
  (`scripts/fork.sh` refuses a busy port); nothing sent to any other node. Robinhood Chain RPC was only
  read (logs, storage, blocks). No browser.
- **P2. PASS.** Every anvil was started by `scripts/fork.sh live` and stopped by its PID file
  (`scripts/test.sh fresh` traps `fork.sh down`); `lsof -iTCP:48470` empty at the end.
- **P3. PASS.** One fresh fork read per code change, replays from the cached block otherwise.
- **P4. PASS.** Build, test, slither, fetch and anvil output in `logs/`; only tails read.

## Evidence
- `scripts/test.sh fresh` pins the latest Robinhood Chain block, reads it once through a local anvil and
  saves the fork cache to `state/rpc-cache.json`; `scripts/test.sh` replays that block (state/FORK_BLOCK)
  with no state reads. **39 tests, 39 passed** at block 91,045,422:
  - `test/AmAmm.t.sol` 8: BidDog rules one by one, and `testFuzz_lazyEqualsEveryBlock` (48 random
    histories of 6 bids over up to 14,400-block gaps: a pool touched only now and then charges the same
    rent, holds the same seat and owes the same refunds as one updated every block; with BidDog's
    original run-dry rule it fails on the 5th history, `logs/biddog_original.log`).
  - `test/fork/Landlord.t.sol` 19 on the real PoolManager, SPCX and USDG: one pool per pair, liquidity
    only through the books, donations refused, principal round trip, slippage and price window, no-seat
    fees to LPs by liquidity, **LPs receive rent owed to the unit** (two LPs joining at different times),
    holder swaps free and others pay the holder, fee from the next block, outbid after exactly K with
    refund, run-dry back to 0.3%, reserve rent, withdrawal fee, **holder cannot touch LP principal**
    (fee-free round trips, max fee, remove/collect attempts: LP leaves with its value less 13 ppm),
    **griefing bounded** (two griefers resetting the queue 6 times: the seat never changes hands early
    and the winner pays at least 1.1^6 the old rent), burn crank, crank cap, sandwich loses money, burn
    pool checks, CREATE2 deployment at a flagged address.
  - `test/fork/Solvency.t.sol` 2 invariants, 64 runs x 120 random calls (LPs add/remove/collect,
    traders and seat holders swap, bids, deposits, withdrawals, fee changes, claims, block jumps up to
    2K, cranks): **USDG and SPCX balances always cover every deposit, refund, fee, LP claim and burn
    share, with only rounding dust left**; the LP books always equal the PoolManager's liquidity.
    The handler counts what each run exercised; the last runs logged 8 accepted bids, 3 to 5 seat
    changes, a seat held after 22 to 45 of the 120 calls and 3 to 4 burns (`logs/inv.log`).
  - `test/fork/Replay.t.sol` 4: the measurement above.
  - `test/fork/SeatDesk.t.sol` 6: one desk per wallet at the computed CREATE2 address (a stranger gets
    its own); every desk function refuses non-owners and the callback refuses anyone but the
    PoolManager; the owner's swap through the desk books no fee while the same trade by a router user
    pays 0.3% to the desk; other pools and too-little output refused; fee change, top-up (no approval
    left behind), withdrawal (paid to the wallet, locked below K blocks), fee claim and refund after
    being outbid all through the desk; **the desk holds zero USDG and zero SPCX after every action**.
- `forge build`: 0 compiler warnings, 0 lint notes on `src/`. Landlord runtime 20,191 bytes.
- `slither . --filter-paths "lib/|test/|script/"` (0.11.5): 18 results, 7 detectors, none exploitable.
  SeatDesk adds two: `missing-zero-check` on the owner (the factory always passes `msg.sender`) and
  `unused-return` on `settle()` (the amount is fixed by the swap delta). The rest:
  `reentrancy-no-eth`/`reentrancy-benign` (crank and remove write totals after the PoolManager
  `unlock`; both are behind the transient `nonReentrant` lock and call only the PoolManager; `afterSwap`
  was reordered to book before `take`); `incorrect-equality` (`lastUpdatedBlockIdx == currentBlockIdx`
  is BidDog's once-per-block guard, exact by design); `uninitialized-local` (bools that start false on
  purpose); `unused-return` (`getSlot0` fields not needed; `modifyLiquidity` fee delta is always empty
  because the position never earns v4 fees).
- Deploy dry run: `forge script script/Deploy.s.sol --tc Deploy --fork-url <hood> --skip-simulation`
  mined a hook address, deployed the desk factory next to it and opened SPCX/USDG at the reference
  pool's price (no broadcast).
