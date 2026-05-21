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
    Currency public immutable quote;
    /// @notice The token bought and burned with the rent's burn share.
    Currency public immutable burnToken;
    // burn pool key, stored field by field (immutables cannot be structs)
    Currency private immutable burnCurrency0;
    Currency private immutable burnCurrency1;
    uint24 private immutable burnFee;
    int24 private immutable burnTickSpacing;

    struct Pool {
        bool registered;
        bool quoteIs0;
        uint128 liquidity; // sum of LP liquidity; equals the hook's position in the PoolManager
        uint256 rentPerLiquidityX128;
        uint256 fee0PerLiquidityX128;
        uint256 fee1PerLiquidityX128;
    }

    struct Position {
        uint128 liquidity;
        uint256 rentCheckpointX128;
        uint256 fee0CheckpointX128;
        uint256 fee1CheckpointX128;
        uint256 owed0;
        uint256 owed1;
    }

    mapping(PoolId => Pool) public pools;
    mapping(PoolId => mapping(address => Position)) public positions;

    /// @notice Quote waiting to be spent by `crankBurn`.
    uint256 public burnBucket;
    uint256 public totalBurnSpent;
    uint256 public totalBurned;
    uint256 public lastBurnBlock;

    enum Action {
        Add,
        Remove,
        Burn
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @dev Transient-storage lock on every external entry point that moves tokens.
    modifier nonReentrant() {
        bool locked;
        assembly ("memory-safe") {
            locked := tload(0)
        }
        if (locked) revert Reentrancy();
        assembly ("memory-safe") {
            tstore(0, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(0, 0)
        }
    }

    /// @param burnPoolKey_ A plain v4 pool (no hook, static fee of at least 0.3%) pairing `quote_`
    /// with `burnToken_`. Must be initialized before the first crank.
    constructor(IPoolManager poolManager_, Currency quote_, Currency burnToken_, PoolKey memory burnPoolKey_) {
        bool pairOk = (burnPoolKey_.currency0 == quote_ && burnPoolKey_.currency1 == burnToken_)
            || (burnPoolKey_.currency1 == quote_ && burnPoolKey_.currency0 == burnToken_);
        if (
            !pairOk || address(burnPoolKey_.hooks) != address(0) || burnPoolKey_.fee < 3000
                || LPFeeLibrary.isDynamicFee(burnPoolKey_.fee) || quote_.isAddressZero() || burnToken_.isAddressZero()
        ) revert InvalidBurnPool();

        Hooks.validateHookPermissions(
            this,
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: true,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: true,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
        poolManager = poolManager_;
        quote = quote_;
        burnToken = burnToken_;
        burnCurrency0 = burnPoolKey_.currency0;
        burnCurrency1 = burnPoolKey_.currency1;
        burnFee = burnPoolKey_.fee;
        burnTickSpacing = burnPoolKey_.tickSpacing;
    }

    // ---------------------------------------------------------------------
    // Liquidity
    // ---------------------------------------------------------------------

    /// @notice Add full-range liquidity. Pays at most `amount0Max` / `amount1Max`; reverts unless the
    /// pool price is inside [`sqrtPriceMinX96`, `sqrtPriceMaxX96`] so a moved price cannot fill the order.
    function addLiquidity(
        PoolKey calldata key,
        uint128 liquidity,
        uint256 amount0Max,
        uint256 amount1Max,
        uint160 sqrtPriceMinX96,
        uint160 sqrtPriceMaxX96
    ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        PoolId id = key.toId();
        Pool storage pool = _registered(id);
        if (liquidity == 0) revert ZeroLiquidity();
        _checkPrice(id, sqrtPriceMinX96, sqrtPriceMaxX96);

        _updateAmAmmWrite(id);
        Position storage pos = positions[id][msg.sender];
        _accrue(pool, pos);
        pos.liquidity += liquidity;
        pool.liquidity += liquidity;

        (amount0, amount1) = abi.decode(
            poolManager.unlock(abi.encode(Action.Add, abi.encode(key, msg.sender, liquidity))), (uint256, uint256)
        );
        if (amount0 > amount0Max || amount1 > amount1Max) revert SlippageExceeded();

        emit Deposit(id, msg.sender, liquidity, amount0, amount1);
    }

    /// @notice Remove liquidity. While a seat is held, WITHDRAW_FEE of both amounts goes to the holder.
    function removeLiquidity(
        PoolKey calldata key,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint160 sqrtPriceMinX96,
        uint160 sqrtPriceMaxX96
    ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        PoolId id = key.toId();
        Pool storage pool = _registered(id);
        if (liquidity == 0) revert ZeroLiquidity();
        _checkPrice(id, sqrtPriceMinX96, sqrtPriceMaxX96);

        _updateAmAmmWrite(id);
        Position storage pos = positions[id][msg.sender];
        if (pos.liquidity < liquidity) revert InsufficientLiquidity();
        _accrue(pool, pos);
        pos.liquidity -= liquidity;
        pool.liquidity -= liquidity;

        address holder = _topBids[id].manager;
        uint24 withdrawFee = holder == address(0) ? 0 : WITHDRAW_FEE;
        uint256 fee0;
        uint256 fee1;
        (amount0, amount1, fee0, fee1) = abi.decode(
            poolManager.unlock(abi.encode(Action.Remove, abi.encode(key, msg.sender, liquidity, withdrawFee))),
            (uint256, uint256, uint256, uint256)
        );
        if (amount0 < amount0Min || amount1 < amount1Min) revert SlippageExceeded();
        if (fee0 != 0) _accrueFees(holder, key.currency0, fee0);
        if (fee1 != 0) _accrueFees(holder, key.currency1, fee1);

        emit Withdraw(id, msg.sender, liquidity, amount0, amount1, fee0, fee1);
    }

    /// @notice Pay out the caller's rent and no-seat swap fees for a pool.
    function collect(PoolKey calldata key, address recipient)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        PoolId id = key.toId();
        Pool storage pool = _registered(id);
        _updateAmAmmWrite(id);
        Position storage pos = positions[id][msg.sender];
        _accrue(pool, pos);
        (amount0, amount1) = (pos.owed0, pos.owed1);
        pos.owed0 = 0;
        pos.owed1 = 0;
        if (amount0 != 0) _transfer(key.currency0, recipient, amount0);
        if (amount1 != 0) _transfer(key.currency1, recipient, amount1);
        emit Collect(id, msg.sender, amount0, amount1);
    }

    /// @notice What `collect` would pay the owner now, including rent not yet charged.
    function owed(PoolKey calldata key, address owner) external view returns (uint256 amount0, uint256 amount1) {
        PoolId id = key.toId();
        Pool memory pool = pools[id];
        Position memory pos = positions[id][owner];
        uint256 pendingRent = _pendingRent(id);
        if (pool.liquidity != 0 && pendingRent != 0) {
            pool.rentPerLiquidityX128 += FullMath.mulDiv(pendingRent - _burnPart(pendingRent), Q128, pool.liquidity);
        }
        uint256 rent = FullMath.mulDiv(pos.liquidity, pool.rentPerLiquidityX128 - pos.rentCheckpointX128, Q128);
        amount0 = pos.owed0 + FullMath.mulDiv(pos.liquidity, pool.fee0PerLiquidityX128 - pos.fee0CheckpointX128, Q128);
        amount1 = pos.owed1 + FullMath.mulDiv(pos.liquidity, pool.fee1PerLiquidityX128 - pos.fee1CheckpointX128, Q128);
        if (pool.quoteIs0) amount0 += rent;
        else amount1 += rent;
    }

    /// @notice Lowest rent a bid can name now, in quote units per block.
    function minRent(PoolId id) external view returns (uint128) {
        return _minRent(id);
    }

    /// @notice The swap fee a non-holder pays right now, in pips.
    function currentFee(PoolId id) external view returns (uint24) {
        (Bid memory topBid,) = _updateAmAmmView(id);
        return topBid.manager == address(0) ? DEFAULT_FEE : _feeAt(topBid, _blockIdx());
    }

    // ---------------------------------------------------------------------
    // Burn
    // ---------------------------------------------------------------------

    /// @notice Anyone can call: spends burn-share rent on the burn token in the burn pool and sends
    /// every unit bought to 0xdEaD. At most once per block and at most BURN_MAX_DEPTH of the pool's
    /// in-range quote depth per call.
    function crankBurn() external nonReentrant returns (uint256 spent, uint256 burned) {
        uint256 blockNumber = _blockNumber();
        if (lastBurnBlock == blockNumber) revert BurnAlreadyCrankedThisBlock();
        PoolKey memory key = burnPoolKey();
        PoolId id = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        uint128 depth = poolManager.getLiquidity(id);
        if (sqrtPriceX96 == 0 || depth == 0) revert InvalidBurnPool();

        bool quoteIs0 = key.currency0 == quote;
        uint256 quoteDepth = quoteIs0
            ? FullMath.mulDiv(depth, FixedPoint96.Q96, sqrtPriceX96)
            : FullMath.mulDiv(depth, sqrtPriceX96, FixedPoint96.Q96);
        uint256 amountIn = burnBucket;
        uint256 cap = quoteDepth * BURN_MAX_DEPTH / PIPS;
        if (amountIn > cap) amountIn = cap;
        if (amountIn == 0) revert NothingToBurn();

        lastBurnBlock = blockNumber;
        (spent, burned) = abi.decode(
            poolManager.unlock(abi.encode(Action.Burn, abi.encode(key, quoteIs0, amountIn))), (uint256, uint256)
        );
        burnBucket -= spent;
        totalBurnSpent += spent;
        totalBurned += burned;
        emit Burn(msg.sender, spent, burned);
    }

    function burnPoolKey() public view returns (PoolKey memory) {
        return PoolKey(burnCurrency0, burnCurrency1, burnFee, burnTickSpacing, IHooks(address(0)));
    }

    // ---------------------------------------------------------------------
    // PoolManager callbacks
    // ---------------------------------------------------------------------

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (Action action, bytes memory args) = abi.decode(data, (Action, bytes));
        if (action == Action.Add) {
            (PoolKey memory key, address payer, uint128 liquidity) = abi.decode(args, (PoolKey, address, uint128));
            // the position never earns v4 fees (LP fee 0, donations refused), so the fee delta is empty
            (BalanceDelta delta,) = poolManager.modifyLiquidity(key, _fullRange(int256(uint256(liquidity))), "");
            uint256 amount0 = uint256(int256(-delta.amount0()));
            uint256 amount1 = uint256(int256(-delta.amount1()));
            _settleFrom(key.currency0, payer, amount0);
            _settleFrom(key.currency1, payer, amount1);
            return abi.encode(amount0, amount1);
        } else if (action == Action.Remove) {
            (PoolKey memory key, address recipient, uint128 liquidity, uint24 withdrawFee) =
                abi.decode(args, (PoolKey, address, uint128, uint24));
            (BalanceDelta delta,) = poolManager.modifyLiquidity(key, _fullRange(-int256(uint256(liquidity))), "");
            uint256 total0 = uint256(int256(delta.amount0()));
            uint256 total1 = uint256(int256(delta.amount1()));
            uint256 fee0 = total0 * withdrawFee / PIPS;
            uint256 fee1 = total1 * withdrawFee / PIPS;
            _takeSplit(key.currency0, recipient, total0, fee0);
            _takeSplit(key.currency1, recipient, total1, fee1);
            return abi.encode(total0 - fee0, total1 - fee1, fee0, fee1);
        } else {
            (PoolKey memory key, bool quoteIs0, uint256 amountIn) = abi.decode(args, (PoolKey, bool, uint256));
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
            // a price limit 2% away keeps one crank inside the pool's range even if depth is thin
            uint256 limit = quoteIs0 ? uint256(sqrtPriceX96) * 990 / 1000 : uint256(sqrtPriceX96) * 1010 / 1000;
            if (limit <= TickMath.MIN_SQRT_PRICE) limit = TickMath.MIN_SQRT_PRICE + 1;
            if (limit >= TickMath.MAX_SQRT_PRICE) limit = TickMath.MAX_SQRT_PRICE - 1;
            BalanceDelta delta = poolManager.swap(
                key,
                SwapParams({
                    zeroForOne: quoteIs0, amountSpecified: -amountIn.toInt256(), sqrtPriceLimitX96: limit.toUint160()
                }),
                ""
            );
            (int128 paid, int128 got) =
                quoteIs0 ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
            // a swap stopped by the price limit spends less than amountIn; the rest stays in the bucket
            uint256 quotePaid = (-paid).toUint128();
            uint256 bought = got.toUint128();
            _settleFrom(quote, address(this), quotePaid);
            poolManager.take(burnToken, DEAD, bought);
            return abi.encode(quotePaid, bought);
        }
    }

    function beforeInitialize(address, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        // One pool per pair: the hook, fee and tick spacing are fixed, so a pair has exactly one PoolId.
        bool quoteIs0 = key.currency0 == quote;
        if (
            address(key.hooks) != address(this) || key.fee != 0 || key.tickSpacing != TICK_SPACING
                || (!quoteIs0 && !(key.currency1 == quote)) || key.currency0.isAddressZero()
        ) revert InvalidPoolKey();
        Pool storage pool = pools[key.toId()];
        pool.registered = true;
        pool.quoteIs0 = quoteIs0;
        return IHooks.beforeInitialize.selector;
    }

    /// @dev The PoolManager skips hook calls for the hook's own modifyLiquidity, so reaching here
    /// means someone else is trying to provide liquidity outside the share books.
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert LiquidityOnlyThroughHook();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert LiquidityOnlyThroughHook();
    }

    /// @dev A donation would land in the hook's position as v4 fee growth, outside the share books.
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert DonationsDisabled();
    }

    /// @dev The pool's LP fee is 0; the swap fee is taken here on the unspecified side (output of an
    /// exact-in swap, input of an exact-out swap). The holder's own swaps pay nothing.
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        PoolId id = key.toId();
        _updateAmAmmWrite(id);

        Bid memory topBid = _topBids[id];
        uint24 fee = topBid.manager == address(0) ? DEFAULT_FEE : _feeAt(topBid, _blockIdx());
        if (sender == topBid.manager || fee == 0) return (IHooks.afterSwap.selector, 0);

        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        (Currency feeCurrency, int128 unspecified) =
            specifiedIs0 ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());
        if (unspecified < 0) unspecified = -unspecified;
        uint256 feeAmount = uint256(unspecified.toUint128()) * fee / PIPS;
        if (feeAmount == 0) return (IHooks.afterSwap.selector, 0);

        if (topBid.manager != address(0)) {
            _accrueFees(topBid.manager, feeCurrency, feeAmount);
        } else {
            // a nonzero fee implies a nonzero swap, so the pool holds liquidity
            Pool storage pool = pools[id];
            uint256 perLiquidity = FullMath.mulDiv(feeAmount, Q128, pool.liquidity);
            if (feeCurrency == key.currency0) pool.fee0PerLiquidityX128 += perLiquidity;
            else pool.fee1PerLiquidityX128 += perLiquidity;
        }
        emit SwapFee(id, topBid.manager, feeCurrency, feeAmount);
        poolManager.take(feeCurrency, address(this), feeAmount);
        return (IHooks.afterSwap.selector, feeAmount.toInt128());
    }

    // Permissions not granted to this hook; the PoolManager never calls these.
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        pure
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    // ---------------------------------------------------------------------
    // AmAmm wiring
    // ---------------------------------------------------------------------

    function bid(PoolId id, address manager, uint24 fee, uint128 rent, uint128 deposit) public override nonReentrant {
        super.bid(id, manager, fee, rent, deposit);
    }

    function depositIntoBid(PoolId id, uint128 amount, bool isTopBid) public override nonReentrant {
        super.depositIntoBid(id, amount, isTopBid);
    }

    function withdrawFromBid(PoolId id, uint128 amount, address recipient, bool isTopBid) public override nonReentrant {
        super.withdrawFromBid(id, amount, recipient, isTopBid);
    }
