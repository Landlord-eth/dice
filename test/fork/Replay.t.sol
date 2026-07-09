// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

import {Fixture, SeatAgent} from "../utils/Fixture.sol";

/// @notice An outside arbitrageur: trades a pool toward the market price until its marginal price,
/// net of the fee, meets the market. With `rebate` it donates 45% of its profit (marked at the market
/// price) back to the pool's LPs, the way What The Hook describes its rebate.
contract Arbitrageur is IUnlockCallback {
    IPoolManager immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function trade(PoolKey memory key, bool zeroForOne, uint160 limit, uint160 market, bool rebate)
        external
        returns (BalanceDelta d, int256 profit, uint256 donated)
    {
        return abi.decode(pm.unlock(abi.encode(key, zeroForOne, limit, market, rebate)), (BalanceDelta, int256, uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, bool zeroForOne, uint160 limit, uint160 market, bool rebate) =
            abi.decode(data, (PoolKey, bool, uint160, uint160, bool));
        BalanceDelta d = pm.swap(key, SwapParams(zeroForOne, -1e30, limit), "");
        int256 profit = ReplayMath.value(d.amount0(), d.amount1(), market);
        uint256 donated;
        int128 a1 = d.amount1();
        if (rebate && profit > 0) {
            // USDG is currency1 of SPCX/USDG
            donated = uint256(profit) * 45 / 100;
            pm.donate(key, 0, donated, "");
            a1 -= int128(int256(donated));
        }
        _settle(key.currency0, d.amount0());
        _settle(key.currency1, a1);
        return abi.encode(d, profit, donated);
    }

    function _settle(Currency c, int128 amount) private {
        if (amount < 0) {
            pm.sync(c);
            ERC20(Currency.unwrap(c)).transfer(address(pm), uint128(-amount));
            pm.settle();
        } else if (amount > 0) {
            pm.take(c, address(this), uint128(amount));
        }
    }
}

library ReplayMath {
    /// @dev USDG value of signed SPCX/USDG amounts at a sqrt price (SPCX is token0).
    function value(int256 a0, int256 a1, uint160 sqrtPriceX96) internal pure returns (int256) {
        int256 s = int256(uint256(sqrtPriceX96));
        return a1 + (a0 * s / int256(1 << 96)) * s / int256(1 << 96);
    }
}

/// @notice LP outcome on real Robinhood Chain prices: one NASDAQ session of the busiest SPCX/USDG
/// v4 pool (research/data). Three pools with the same full-range liquidity on the real PoolManager
/// follow that price: plain v4, a 45% arbitrage rebate, and LANDLORD with a seat holder.
/// Only arbitrage is replayed; uninformed flow is reported separately (see CORE.md).
contract ReplayForkTest is Fixture {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint128 constant LIQ = 8e16; // about $1M of each token at $147
    uint256 constant PIPS = 1e6;

    uint256[] steps;
    uint160[] prices;
    uint256 windowStart;
    uint48 K;
    Arbitrageur arb;

    struct Plain {
        int256 lp; // LP result vs holding, USDG units
        int256 flow; // LP result vs a portfolio rebalanced at the market price: -(arbitrage taken) + rebates
        int256 arb; // arbitrageur profit at market prices
        uint256 donated;
        uint256 volume; // USDG side of the arbitrage trades
    }

    struct Seat {
        int256 lp; // LP result vs holding, rent included
        int256 flow; // LP result vs a portfolio rebalanced at the market price, rent included
        int256 gross; // seat holder's arbitrage profit + fees, before rent
        uint256 rent; // rent per block
        uint256 rentPaid; // total rent paid by the holder
        int256 outside; // outside arbitrageurs' profit
        bool floorBinds;
    }

    function setUp() public override {
        super.setUp();
        K = hook.K();
        arb = new Arbitrageur(PM);
        _fund(address(arb), 1_000_000_000e6, 10_000_000e18);
        _fund(address(this), 100_000_000e6, 1_000_000e18);
        ERC20(SPCX).approve(address(liqRouter), type(uint256).max);
        ERC20(SPCX).approve(address(hook), type(uint256).max);
        ERC20(USDG).approve(address(hook), type(uint256).max);
    }

    function test_replay_blockPath_fee30bp() public {
        _run("research/data/spcx_path_block.json", "block", 3000);
    }

    function test_replay_blockPath_fee5bp() public {
        _run("research/data/spcx_path_block.json", "block", 500);
    }

    function test_replay_blockPath_fee100bp() public {
        _run("research/data/spcx_path_block.json", "block", 10_000);
    }

    function test_replay_minutePath_fee30bp() public {
        _run("research/data/spcx_path_minute.json", "minute", 3000);
    }

    function _run(string memory file, string memory pathName, uint24 fee) internal {
        _load(file);
        windowStart = vm.getBlockNumber() + K;
        uint256 snap = vm.snapshotState();

        Plain memory plain = _plain(fee, false);
        vm.revertToState(snap);
        Plain memory rebate = _plain(fee, true);
        vm.revertToState(snap);

        Seat memory race1 = _seat(fee, true, PIPS, snap);
        Seat memory race5 = _seat(fee, true, PIPS / 2, snap);
        Seat memory mgr1 = _seat(fee, false, PIPS, snap);
        Seat memory mgr5 = _seat(fee, false, PIPS / 2, snap);

        uint256 poolValue = uint256(ReplayMath.value(int256(_amount0(prices[0])), int256(_amount1(prices[0])), prices[0]));
        string memory row = string.concat(pathName, "_", vm.toString(fee));
        vm.serializeUint(row, "fee_pips", fee);
        vm.serializeUint(row, "steps", steps.length);
        vm.serializeUint(row, "window_blocks", steps[steps.length - 1] + 1);
        vm.serializeUint(row, "pool_value_usdg_units", poolValue);
        vm.serializeInt(row, "plain_lp", plain.lp);
        vm.serializeInt(row, "plain_flow", plain.flow);
        vm.serializeInt(row, "rebate_flow", rebate.flow);
        vm.serializeInt(row, "race_full_flow", race1.flow);
        vm.serializeInt(row, "race_half_flow", race5.flow);
        vm.serializeInt(row, "mgr_full_flow", mgr1.flow);
        vm.serializeInt(row, "mgr_half_flow", mgr5.flow);
        vm.serializeUint(row, "burn_share_pips", hook.BURN_SHARE());
        vm.serializeInt(row, "plain_arb_profit", plain.arb);
        vm.serializeUint(row, "plain_arb_volume", plain.volume);
        vm.serializeInt(row, "rebate_lp", rebate.lp);
        vm.serializeUint(row, "rebate_donated", rebate.donated);
        vm.serializeInt(row, "race_full_lp", race1.lp);
        vm.serializeInt(row, "race_full_seat_gross", race1.gross);
        vm.serializeInt(row, "race_full_outside_arb", race1.outside);
        vm.serializeUint(row, "race_full_rent_per_block", race1.rent);
        vm.serializeBool(row, "race_full_floor_binds", race1.floorBinds);
        vm.serializeInt(row, "race_half_lp", race5.lp);
        vm.serializeUint(row, "race_half_rent_per_block", race5.rent);
        vm.serializeInt(row, "mgr_full_lp", mgr1.lp);
        string memory json = vm.serializeInt(row, "mgr_full_seat_gross", mgr1.gross);
        vm.writeJson(json, string.concat("research/out/replay_", row, ".json"));

        console2.log("path, fee pips", pathName, fee);
        console2.log("pool value USDG", poolValue / 1e6);
        console2.log("plain LP (USDG units)", plain.lp);
        console2.log("rebate LP", rebate.lp);
        console2.log("landlord LP, race, full competition", race1.lp);
        console2.log("landlord LP, race, half competition", race5.lp);
        console2.log("landlord LP, holder wins all, full", mgr1.lp);

        // the seat holder at full competition pays all it earns back as rent: LPs keep 90% of it
        if (!race1.floorBinds) assertApproxEqRel(race1.rentPaid, uint256(race1.gross), 0.01e18);
    }

    // ---------------------------------------------------------------------

    function _load(string memory file) internal {
        string memory raw = vm.readFile(file);
        steps = vm.parseJsonUintArray(raw, ".blocks");
        string[] memory p = vm.parseJsonStringArray(raw, ".sqrtPrices");
        delete prices;
        for (uint256 i; i < p.length; ++i) prices.push(uint160(vm.parseUint(p[i])));
    }

    /// @dev Plain v4 pool (tick spacing 59/57 so the key is new on the real PoolManager).
    function _plain(uint24 fee, bool rebate) internal returns (Plain memory r) {
        PoolKey memory k = PoolKey(key.currency0, key.currency1, fee, rebate ? int24(57) : int24(59), IHooks(address(0)));
        PM.initialize(k, prices[0]);
        ModifyLiquidityParams memory full =
            ModifyLiquidityParams(TickMath.minUsableTick(k.tickSpacing), TickMath.maxUsableTick(k.tickSpacing), int256(uint256(LIQ)), 0);
        (uint256 u0, uint256 s0) = (_usdg(address(this)), _spcx(address(this)));
        liqRouter.modifyLiquidity(k, full, "");
        int256 in0 = int256(s0 - _spcx(address(this)));
        int256 in1 = int256(u0 - _usdg(address(this)));

        uint256 q = _sqrt((PIPS - fee) * 1e30); // sqrt(1 - fee) * 1e18
        for (uint256 i; i < steps.length; ++i) {
            vm.roll(windowStart + steps[i]);
            (int256 p, uint256 d, uint256 v) = _arbTo(k, prices[i], q, rebate);
            r.arb += p;
            r.donated += d;
            r.volume += v;
        }
        (u0, s0) = (_usdg(address(this)), _spcx(address(this)));
        full.liquidityDelta = -full.liquidityDelta;
        liqRouter.modifyLiquidity(k, full, "");
        int256 out0 = int256(_spcx(address(this)) - s0);
        int256 out1 = int256(_usdg(address(this)) - u0);
        uint160 last = prices[prices.length - 1];
        r.lp = ReplayMath.value(out0, out1, last) - ReplayMath.value(in0, in1, last);
        // fees the arbitrageur paid went to the LP, so the LP's loss at market prices is its net profit
        r.flow = -r.arb + int256(r.donated);
    }

    /// @dev LANDLORD pool. Pass 1 seats a holder at the reserve rent and measures what the seat
    /// earns; pass 2 replays with the rent a bidder at `competition` (pips of the seat's earnings)
    /// would pay, through a real bid, and measures what the LP ends with.
    function _seat(uint24 fee, bool race, uint256 competition, uint256 snap) internal returns (Seat memory r) {
        vm.revertToState(snap);
        Seat memory pass1 = _seatPass(fee, race, 0);
        vm.revertToState(snap);
        uint256 blocks = steps[steps.length - 1] + 1;
        uint256 rent = pass1.gross > 0 ? uint256(pass1.gross) * competition / PIPS / blocks : 0;
        r = _seatPass(fee, race, rent);
    }

    function _seatPass(uint24 fee, bool race, uint256 rentWanted) internal returns (Seat memory r) {
        // move the empty pool to the session's opening price, then add the LP
        router.swap(key, SwapParams(prices[0] < startPrice, -1, prices[0]), PoolSwapTest.TestSettings(false, false), "");
        (uint256 u0, uint256 s0) = (_usdg(lp1), _spcx(lp1));
        _add(lp1, LIQ);
        int256 in0 = int256(s0 - _spcx(lp1));
        int256 in1 = int256(u0 - _usdg(lp1));

        SeatAgent holder = new SeatAgent(PM, hook);
        _fund(address(holder), 500_000_000e6, 1_000_000e18);
        uint128 floor_ = hook.minRent(id);
        r.rent = rentWanted < floor_ ? floor_ : rentWanted;
        r.floorBinds = rentWanted != 0 && rentWanted < floor_;
        uint256 blocks = steps[steps.length - 1] + 1;
        holder.bid(id, fee, uint128(r.rent), uint128(r.rent * (blocks + 2 * uint256(K))));
        vm.roll(windowStart);

        uint256 q = _sqrt((PIPS - fee) * 1e30);
        for (uint256 i; i < steps.length; ++i) {
            vm.roll(windowStart + steps[i]);
            uint160 market = prices[i];
            if (race) {
                (int256 p,,) = _arbTo(key, market, q, false);
                r.outside += p;
            }
            (uint160 now_,,,) = PM.getSlot0(id);
            if (now_ != market) {
                BalanceDelta d = holder.swap(key, now_ > market, -1e30, market);
                r.gross += ReplayMath.value(d.amount0(), d.amount1(), market);
            }
        }
        vm.roll(windowStart + blocks);
        hook.updateStateMachine(id);
        uint160 last = prices[prices.length - 1];
        r.gross += ReplayMath.value(
            int256(hook.getFees(address(holder), key.currency0)), int256(hook.getFees(address(holder), key.currency1)), last
        );
        r.rentPaid = r.rent * blocks;
        (, uint256 rentToLp) = hook.owed(key, lp1);
        // everything the holder and outside arbitrageurs made (fees included) came out of the pool
        r.flow = int256(rentToLp) - r.gross - r.outside;

        (u0, s0) = (_usdg(lp1), _spcx(lp1));
        _remove(lp1, LIQ);
        vm.prank(lp1);
        hook.collect(key, lp1);
        int256 out0 = int256(_spcx(lp1) - s0);
        int256 out1 = int256(_usdg(lp1) - u0);
        r.lp = ReplayMath.value(out0, out1, last) - ReplayMath.value(in0, in1, last);
    }

    /// @dev Outside arbitrage to the edge of the no-trade band around `market`.
    function _arbTo(PoolKey memory k, uint160 market, uint256 q, bool rebate)
        internal
        returns (int256 profit, uint256 donated, uint256 volume)
    {
        (uint160 p,,,) = PM.getSlot0(k.toId());
        uint160 up = uint160(uint256(market) * q / 1e18); // buy SPCX up to here
        uint160 down = uint160(uint256(market) * 1e18 / q); // sell SPCX down to here
        BalanceDelta d;
        if (p < up) (d, profit, donated) = arb.trade(k, false, up, market, rebate);
        else if (p > down) (d, profit, donated) = arb.trade(k, true, down, market, rebate);
        int128 a1 = d.amount1();
        volume = uint256(int256(a1 < 0 ? -a1 : a1));
    }

    function _amount0(uint160 s) internal pure returns (uint256) {
        return uint256(LIQ) * (1 << 96) / s;
    }

    function _amount1(uint160 s) internal pure returns (uint256) {
        return uint256(LIQ) * s / (1 << 96);
    }
}
