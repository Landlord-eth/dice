// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {AmAmm} from "./AmAmm.sol";

/// @title Landlord
/// @notice A Uniswap v4 hook that turns a TOKEN/QUOTE pool into an auction-managed AMM
/// (am-AMM, arXiv 2403.03367). The hook is the pool's only liquidity provider: it holds one
/// full-range position per pool and books every LP's share of it, so every unit of liquidity
/// earns the same rent, as the paper's constant-product result needs.
///
/// While a seat holder exists it pays rent per block from its deposit (96% to LPs, 4% bought
/// and burned as the LANDLORD token), sets the swap fee up to 1%, keeps every swap fee and swaps
/// fee-free. With no holder the fee is 0.3% and goes to the LPs.
///
/// No owner, no admin, no upgrade path. Everything a pool needs is a launch constant.
contract Landlord is AmAmm, IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeTransferLib for ERC20;
    using SafeCast for uint256;
    using SafeCast for int128;

    error NotPoolManager();
    error HookNotImplemented();
    error InvalidPoolKey();
    error PoolNotRegistered();
    error LiquidityOnlyThroughHook();
    error DonationsDisabled();
    error ZeroLiquidity();
    error InsufficientLiquidity();
    error SlippageExceeded();
    error PriceOutOfBounds();
    error Reentrancy();
    error InvalidBurnPool();
    error BurnAlreadyCrankedThisBlock();
    error NothingToBurn();

    event Deposit(PoolId indexed id, address indexed owner, uint128 liquidity, uint256 amount0, uint256 amount1);
    event Withdraw(
        PoolId indexed id,
        address indexed owner,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1,
        uint256 fee0,
        uint256 fee1
    );
    event Collect(PoolId indexed id, address indexed owner, uint256 amount0, uint256 amount1);
    event RentCharged(PoolId indexed id, uint256 toLps, uint256 toBurn);
    event SwapFee(PoolId indexed id, address indexed manager, Currency currency, uint256 amount);
    event Burn(address indexed caller, uint256 quoteSpent, uint256 tokenBurned);

    /// @notice Swap fee with no seat holder, in pips (0.3%), paid to the LPs.
    uint24 public constant DEFAULT_FEE = 3000;
    /// @notice Withdrawal fee while a seat is held, in pips. Paper appendix B: 1 - 2 sqrt(1 + c) / (2 + c)
    /// is 12.38 ppm for the 1% fee cap; rounded up. It stops LPs leaving between a price move and the
    /// holder's arbitrage of it.
    uint24 public constant WITHDRAW_FEE = 13;
    /// @notice Share of rent that buys and burns the LANDLORD token, in pips (4%). Every unit of it
    /// comes out of the LPs' rent, so it is the largest share at which a fully competed seat still left
    /// LPs ahead of both plain v4 and a 45% arbitrage rebate at the 0.3% fee in the replayed session.
    uint24 public constant BURN_SHARE = 40_000;
    /// @notice Reserve rent: 1% a year of the pool's value at bid time. Set under what arbitrage alone
    /// paid a full-range SPCX/USDG seat in the replay of a real session (1.3% to 2.5% a year), so an
    /// active stock pool can always seat a bidder, while a dead pool is not given away for nothing.
    uint256 public constant MIN_RENT_PER_YEAR_PIPS = 10_000;
    /// @notice Robinhood Chain blocks per year at the measured 0.1 s block time.
    uint256 public constant BLOCKS_PER_YEAR = 315_360_000;
    /// @notice A crank spends at most this share of the burn pool's in-range quote depth, in pips (0.1%).
    /// Pushing the price up to make the crank overpay costs the pusher the burn pool's fee on twice
    /// the push; with a fee of at least 0.3% that is more than the overpayment at this size.
    uint24 public constant BURN_MAX_DEPTH = 1000;
    int24 public constant TICK_SPACING = 60;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint24 private constant PIPS = 1_000_000;
    uint256 private constant Q128 = 1 << 128;

    IPoolManager public immutable poolManager;
    /// @notice The rent and bid currency, one side of every pool (USDG on Robinhood Chain).
