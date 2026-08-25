# LANDLORD security notes

Three files: `src/AmAmm.sol` (the seat auction, ported from Bunni's BidDog), `src/Landlord.sol`
(the Uniswap v4 hook: LP books, fees, rent, burn) and `src/SeatDesk.sol` (a wallet's seat contract). No owner, no admin, no proxy, no pause.

## Trust assumptions
- **Uniswap v4 PoolManager** `0x8366…0951` on Robinhood Chain. All pool math is v4-core's.
- **USDG** (the rent and bid currency) and the **pool tokens** behave as plain ERC20s. Robinhood
  stock tokens can be paused, can block an address, and can be burned from any holder by their
  issuer (`adminBurn`). If the issuer blocks the hook or pauses a token, that pool's swaps, deposits
  and withdrawals stop until it is lifted; the hook cannot route around it. This is the issuer's
  power over every holder of the token, not something the hook adds.
- **Robinhood Chain's sequencer** orders transactions first come, first served. It can delay or
  censor any transaction. The auction delay K (7,200 blocks, 12 minutes) stops a bidder from
  grabbing the seat for a moment it already sees, but it does not protect against the sequencer
  itself censoring for 12 minutes; only the chain's force-inclusion path (about 24 hours on
  Arbitrum Orbit) bounds that. Stated plainly in CORE.md.
- **ArbSys precompile** (`0x64`) for the chain's own block number. On Robinhood Chain `block.number`
  is the Ethereum block number (measured: 26,212,905 when the chain was at block 91,001,176), so
  K, rent per block and "once per block" all read `arbBlockNumber()`.

## What each check defends
| Check | Attack it stops |
|---|---|
| `beforeInitialize`: hook = this, fee 0, tick spacing 60, one side USDG, no native ETH | Second pools for the same pair (E2), pools whose fee bypasses the hook, pools the books cannot pay out of |
| `beforeAddLiquidity` / `beforeRemoveLiquidity` revert (the PoolManager skips the hook's own calls) | Liquidity outside the share books: it would dilute rent and fees without being booked |
| `beforeDonate` reverts | A donation would land in the hook's position as v4 fee growth, outside the books |
| `_updateAmAmmWrite` before every share change, swap, bid and claim | Joining just before a rent charge to take rent for blocks one was not in the pool |
| Fee from the next block (`prevFee` / `feeBlockIdx`) | A holder repricing a block it has already seen |
| Holder fee-free only when `sender == manager` | Anyone else swapping at the holder's zero fee |
| Bid: `rent > 1.1 x queued`, `deposit >= K x rent`, `deposit % rent == 0`, `rent >= minRent`, `fee <= 1%`, manager != 0 | Free queue resets, seats that can quit sooner than K blocks, squatting a pool for a token rent, fees above the cap |
| `withdrawFromBid` keeps `deposit / rent >= K`; no cancel | Bidding, then walking away before paying K blocks |
| Withdrawal fee 13 ppm while a seat is held | LPs leaving between a price move and the holder's arbitrage of it (paper appendix B) |
| `addLiquidity`/`removeLiquidity` take amount limits and a price window | A moved price filling a deposit or withdrawal at a bad ratio |
| `nonReentrant` (transient lock) on every external entry that moves tokens | A hostile pool token calling back into the hook mid-transfer |
| `crankBurn`: once per block, at most 0.1% of the burn pool's in-range USDG depth, price limit 2%, burn pool must be hookless with a fee of at least 0.3% | Sandwiching the crank: pushing the price costs 0.3% on twice the push, more than the crank can overpay at that size (test `test_sandwichingTheCrankLosesMoney`) |
| Bought tokens go to `0xdEaD` | No balance is ever left for anyone to take |
| SeatDesk: owner only, fixed list of seat calls, no arbitrary call, hook fixed at construction | A signature on the desk moving the owner's approved tokens anywhere else |
| SeatDesk: `unlockCallback` only from the PoolManager, swaps only on this hook's pools, `paid <= amountIn`, `minOut` | Draining the owner's approval through a callback or a hostile hook's delta |
| SeatDesk: every hook payout names the owner, top-ups approve the exact amount and pass through | Funds stuck in or taken from the desk (it holds nothing between calls) |
| SeatDeskFactory: salt = caller, `deskOf` | Opening a desk in someone else's name, two desks per wallet |

## Rounding
Every share division rounds down: rent and fees per unit of liquidity (`FullMath.mulDiv(x, 2^128, L)`)
and withdrawal fees. The hook can only keep dust, never owe more than it holds. The invariant test
(`test/fork/Solvency.t.sol`) checks after every random call that USDG and SPCX balances cover every
deposit, refund, fee, LP claim and burn share, and that the leftover is dust.

## Changes from BidDog, each on purpose
- A queued bid that waits for a run-dry seat starts at the exact block the deposit ran out. BidDog
  starts it at the block of the next touch, leaving the gap unpaid. With the fix a pool touched now
  and then charges exactly what a pool touched every block charges (`testFuzz_lazyEqualsEveryBlock`).
- BidDog computes `latestProcessedBlockIdx - K` unchecked; before K blocks have passed since
  deployment that underflows. The port guards it.
- `increaseBidRent` and `setBidPayload` with arbitrary payloads are not ported; the only payload is
  the fee.

## Known limitations
- Full range only. The paper's equal-rent result needs every unit of liquidity to be the same; a
  full-range LP earns less fee per dollar than a concentrated one in quiet markets.
- LP positions are books inside the hook, not transferable tokens.
- The seat holder must swap from the contract that holds the bid (`sender` is the contract calling
  the PoolManager, so a public router's swaps pay the fee even when the holder sends them).
- The rent floor reads the pool's current price. Moving the price to lower the floor costs the
  mover the arbitrage back, and a lower floor only lets a bid through that others can outbid.
- With no competing bidders a seat holder can rent at the floor and keep every fee. LPs can leave
  (paying 13 ppm); the auction only pays LPs well when bidders compete. See CORE.md.

## Tooling
- `forge build`: compiles with no compiler warnings; `forge lint` notes are listed in CORE.md.
- `slither .`: see CORE.md for the run and each finding's disposition.
