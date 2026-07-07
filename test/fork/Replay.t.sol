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
