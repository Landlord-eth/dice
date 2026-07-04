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

    function test_slippageAndPriceBounds() public {
        vm.startPrank(lp1);
        vm.expectRevert(Landlord.SlippageExceeded.selector);
        hook.addLiquidity(key, L, 1, type(uint256).max, 0, type(uint160).max);
        vm.expectRevert(Landlord.PriceOutOfBounds.selector);
        hook.addLiquidity(key, L, type(uint256).max, type(uint256).max, startPrice + 1, type(uint160).max);
        vm.expectRevert(Landlord.ZeroLiquidity.selector);
        hook.addLiquidity(key, 0, type(uint256).max, type(uint256).max, 0, type(uint160).max);
        vm.stopPrank();
        _add(lp1, L);
        vm.prank(lp2);
        vm.expectRevert(Landlord.InsufficientLiquidity.selector);
        hook.removeLiquidity(key, 1, 0, 0, 0, type(uint160).max);
    }

    // -----------------------------------------------------------------
    // No seat: a normal 0.3% pool for the LPs
    // -----------------------------------------------------------------

    function test_noSeatFeeGoesToLpsByLiquidity() public {
        _add(lp1, L);
        _add(lp2, L / 2);
        assertEq(hook.currentFee(id), 3000);
        BalanceDelta d = _swap(trader, false, 10_000e6); // USDG in, SPCX out
        uint256 out = uint256(int256(d.amount0()));
        // fee is 0.3% of the gross output, taken from it
        uint256 fee = (out * 1_000_000 / 997_000) * 3000 / 1_000_000;
        (uint256 o0,) = hook.owed(key, lp1);
        (uint256 p0,) = hook.owed(key, lp2);
        assertApproxEqRel(o0 + p0, fee, 1e15);
        assertApproxEqAbs(o0, 2 * p0, 2);
        vm.prank(lp1);
        (uint256 c0,) = hook.collect(key, lp1);
        assertEq(c0, o0, "collect pays what owed() shows");
    }

    // -----------------------------------------------------------------
    // The seat: rent to LPs, fees to the holder
    // -----------------------------------------------------------------

    function test_lpsReceiveRentOwedExactly() public {
        _add(lp1, L);
        SeatAgent agent = _agent(agentOwner);
        uint128 rent = 5_000; // 0.005 USDG a block, $432 a day
        vm.prank(agentOwner);
        agent.bid(id, 2000, rent, rent * K * 4);

        vm.roll(vm.getBlockNumber() + K - 1);
        assertEq(hook.getBid(id, true).manager, address(0), "no seat before K blocks");
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(hook.getBid(id, true).manager, address(agent), "seat after K blocks");

        uint256 n1 = 1234;
        vm.roll(vm.getBlockNumber() + n1);
        _add(lp2, L / 2); // joins: rent before this goes to lp1 alone
        uint256 n2 = 3000;
        vm.roll(vm.getBlockNumber() + n2);
        hook.updateStateMachine(id);

        uint256 toLps1 = rent * n1 - _burn(rent * n1);
        uint256 toLps2 = rent * n2 - _burn(rent * n2);
        (, uint256 r1) = hook.owed(key, lp1);
        (, uint256 r2) = hook.owed(key, lp2);
        assertApproxEqAbs(r1, toLps1 + toLps2 * 2 / 3, 2, "lp1 rent");
        assertApproxEqAbs(r2, toLps2 / 3, 2, "lp2 rent");
        assertEq(hook.burnBucket(), _burn(rent * n1) + _burn(rent * n2), "burn share");

        uint256 before = _usdg(lp1);
        vm.prank(lp1);
        hook.collect(key, lp1);
        assertEq(_usdg(lp1) - before, r1, "rent paid out in USDG");
    }

    function test_holderSwapsFreeOthersPayTheHolder() public {
        _add(lp1, L);
        SeatAgent agent = _seat(agentOwner, 5000, 2000);

        uint256 spcxBefore = _spcx(address(agent));
        vm.prank(agentOwner);
        BalanceDelta free = agent.swap(key, false, -int256(10_000e6), TickMath.MAX_SQRT_PRICE - 1);
        assertEq(_spcx(address(agent)) - spcxBefore, uint256(int256(free.amount0())));
        assertEq(hook.getFees(address(agent), key.currency0), 0, "no fee on own swap");

        // undo the price move so the trader sees the same price
        vm.prank(agentOwner);
        agent.swap(key, true, -int256(free.amount0()), TickMath.MIN_SQRT_PRICE + 1);

        BalanceDelta paid = _swap(trader, false, 10_000e6);
        uint256 gross = uint256(int256(free.amount0()));
        uint256 net = uint256(int256(paid.amount0()));
        assertApproxEqRel(gross - net, gross * 2000 / 1_000_000, 1e14, "trader paid 0.2%");
        assertApproxEqAbs(hook.getFees(address(agent), key.currency0), gross - net, 10, "fee to holder");
        (uint256 o0,) = hook.owed(key, lp1);
        assertEq(o0, 0, "LPs earn rent, not fees, while the seat is held");

        uint256 booked = hook.getFees(address(agent), key.currency0);
        uint256 b = _spcx(agentOwner);
        vm.prank(agentOwner);
        agent.claimFees(key.currency0);
        assertEq(_spcx(agentOwner) - b, booked);
        assertEq(hook.getFees(address(agent), key.currency0), 0);
    }

    function test_feeChangeAppliesFromTheNextBlock() public {
        _add(lp1, L);
        SeatAgent agent = _seat(agentOwner, 5000, 1000);
        vm.prank(agentOwner);
        agent.setFee(id, 9000, true);
        assertEq(hook.currentFee(id), 1000, "same block: old fee");
        uint256 f0 = _feeOn(1000e6);
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(hook.currentFee(id), 9000);
        uint256 f1 = _feeOn(1000e6);
        assertApproxEqRel(f1, f0 * 9, 1e16);

        vm.prank(agentOwner);
        vm.expectRevert(AmAmm.AmAmm__InvalidFee.selector);
        agent.setFee(id, 10_001, true);
    }

    function test_outbidTakesOverAfterKAndRefundsHolder() public {
        _add(lp1, L);
        SeatAgent a = _seat(agentOwner, 5000, 3000);
        SeatAgent b = _agent(rivalOwner);
        uint256 heldFrom = vm.getBlockNumber();
        vm.prank(rivalOwner);
        b.bid(id, 2500, 5501, 5501 * K * 2);
        vm.roll(vm.getBlockNumber() + K - 1);
        assertEq(hook.getBid(id, true).manager, address(a), "holder keeps the seat for K blocks");
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(hook.getBid(id, true).manager, address(b));
        hook.updateStateMachine(id);
        // a paid exactly K blocks; the rest of its 4K deposit is refunded
        assertEq(hook.getRefund(address(a), id), 5000 * uint256(K) * 4 - 5000 * (vm.getBlockNumber() - heldFrom));
        vm.prank(agentOwner);
        uint256 got = a.claimRefund(id);
        assertEq(got, 5000 * uint256(K) * 3);
    }

    function test_seatRunsDryThenPoolReturnsToDefaultFee() public {
        _add(lp1, L);
        SeatAgent a = _agent(agentOwner);
        vm.prank(agentOwner);
        a.bid(id, 500, 5000, 5000 * K);
        vm.roll(vm.getBlockNumber() + 2 * K);
        hook.updateStateMachine(id);
        assertEq(hook.getBid(id, true).manager, address(0));
        assertEq(hook.currentFee(id), 3000);
        (, uint256 r) = hook.owed(key, lp1);
        assertApproxEqAbs(r, 5000 * uint256(K) - _burn(5000 * uint256(K)), 2, "whole deposit paid out as rent");
    }

    function test_rentBelowReserveIsRefused() public {
        _add(lp1, L);
        SeatAgent a = _agent(agentOwner);
        vm.prank(agentOwner);
        vm.expectRevert(AmAmm.AmAmm__InvalidBid.selector);
        a.bid(id, 3000, 30, 30 * K); // pool is worth ~$1.2M: reserve is ~39 units a block
    }

    function test_withdrawalFeeGoesToHolder() public {
        _add(lp1, L);
        SeatAgent a = _seat(agentOwner, 5000, 3000);
        (uint256 b0, uint256 b1) = _remove(lp1, L / 2);
        uint256 f0 = hook.getFees(address(a), key.currency0);
        uint256 f1 = hook.getFees(address(a), key.currency1);
        assertApproxEqAbs(f0, (b0 + f0) * 13 / 1_000_000, 1);
        assertApproxEqAbs(f1, (b1 + f1) * 13 / 1_000_000, 1);
        assertGt(f1, 0);
    }

    // -----------------------------------------------------------------
    // The holder cannot reach LP principal
    // -----------------------------------------------------------------

    function test_holderCannotTouchLpPrincipal() public {
        (uint256 a0, uint256 a1) = _add(lp1, L);
        SeatAgent a = _seat(agentOwner, 5000, 10_000);

