// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolDonateTest} from "v4-core/test/PoolDonateTest.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {AmAmm} from "../../src/AmAmm.sol";
import {HookAddress} from "../../script/HookAddress.sol";
import {Landlord} from "../../src/Landlord.sol";
import {Fixture, SeatAgent} from "../utils/Fixture.sol";

/// @notice The whole life of a LANDLORD pool on a fork of Robinhood Chain: the real v4
/// PoolManager, real SPCX and USDG.
contract LandlordForkTest is Fixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint128 constant L = 5e16; // about $600k a side at SPCX ~ $150
    uint48 K;

    function setUp() public override {
        super.setUp();
        K = hook.K();
    }

    // -----------------------------------------------------------------
    // One pool per pair (E2) and the closed liquidity book
    // -----------------------------------------------------------------

    function test_onlyTheCanonicalKeyInitializes() public {
        PoolKey memory k = key;
        k.fee = 3000;
        vm.expectRevert();
        PM.initialize(k, startPrice);
        k = key;
        k.tickSpacing = 10;
        vm.expectRevert();
        PM.initialize(k, startPrice);
        // a pair without USDG
        k = _sorted(SPCX, address(standIn), 0, 60, address(hook));
        vm.expectRevert();
        PM.initialize(k, startPrice);
        // the canonical key again
        vm.expectRevert();
        PM.initialize(key, startPrice);
    }

    function test_liquidityOnlyThroughTheBook() public {
        _add(lp1, L);
        vm.startPrank(lp1);
        ERC20(SPCX).approve(address(liqRouter), type(uint256).max);
        ERC20(USDG).approve(address(liqRouter), type(uint256).max);
        vm.expectRevert();
        liqRouter.modifyLiquidity(key, ModifyLiquidityParams(-887220, 887220, 1e12, bytes32(0)), "");
        vm.stopPrank();

        PoolDonateTest donor = new PoolDonateTest(PM);
        vm.startPrank(lp1);
        ERC20(USDG).approve(address(donor), type(uint256).max);
        vm.expectRevert();
        donor.donate(key, 0, 1e6, "");
        vm.stopPrank();
    }

    function test_addThenRemoveReturnsPrincipal() public {
        uint256 s0 = _spcx(lp1);
        uint256 u0 = _usdg(lp1);
        (uint256 a0, uint256 a1) = _add(lp1, L);
        assertGt(a0, 0);
        assertGt(a1, 0);
        assertEq(PM.getLiquidity(id), L, "hook position is the pool");
        (uint256 b0, uint256 b1) = _remove(lp1, L);
        assertApproxEqAbs(b0, a0, 2);
        assertApproxEqAbs(b1, a1, 2);
        assertLe(b0, a0, "rounding favours the pool");
        assertApproxEqAbs(_spcx(lp1), s0, 2);
        assertApproxEqAbs(_usdg(lp1), u0, 2);
    }
