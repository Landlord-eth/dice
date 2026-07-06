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
