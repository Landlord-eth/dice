// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {AmAmm} from "../src/AmAmm.sol";
import {AmAmmHarness} from "./utils/AmAmmHarness.sol";

/// @notice The auction state machine on its own: a pool touched only now and then must charge
/// exactly the rent, and end in exactly the seat, of a pool touched every single block.
contract AmAmmTest is Test {
    PoolId constant ID = PoolId.wrap(bytes32(uint256(1)));
    uint48 K;

    MockERC20 token;
    AmAmmHarness eager; // updated every block: the reference
    AmAmmHarness lazy; // updated only when something happens
    address[3] bidders = [address(0xb1), address(0xb2), address(0xb3)];

    function setUp() public {
        token = new MockERC20("rent", "RENT", 6);
        eager = new AmAmmHarness(token);
        lazy = new AmAmmHarness(token);
        K = eager.K();
        for (uint256 i; i < 3; ++i) {
            token.mint(bidders[i], 1e30);
            vm.startPrank(bidders[i]);
            token.approve(address(eager), type(uint256).max);
            token.approve(address(lazy), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// forge-config: default.fuzz.runs = 48
    function testFuzz_lazyEqualsEveryBlock(uint256 seed) public {
        for (uint256 step; step < 6; ++step) {
            seed = uint256(keccak256(abi.encode(seed)));
            uint256 gap = 1 + seed % (2 * uint256(K));
            for (uint256 b; b < gap; ++b) {
                vm.roll(vm.getBlockNumber() + 1);
                eager.updateStateMachine(ID);
            }
            _check();

            address who = bidders[(seed >> 64) % 3];
            uint128 nextRent = eager.getBid(ID, false).rent;
            uint128 topRent = eager.getBid(ID, true).rent;
            uint128 base = nextRent > topRent ? nextRent : topRent;
            if (base == 0) base = 1000;
            // between 0.6x and 2.1x of the standing rent: some bids are refused, some win, some wait
            uint128 rent = uint128(uint256(base) * (60 + (seed >> 96) % 150) / 100) + 1;
            uint128 deposit = rent * K * uint128(1 + (seed >> 128) % 3);

            vm.prank(who);
            (bool okEager,) = address(eager).call(abi.encodeCall(AmAmm.bid, (ID, who, 3000, rent, deposit)));
            vm.prank(who);
            (bool okLazy,) = address(lazy).call(abi.encodeCall(AmAmm.bid, (ID, who, 3000, rent, deposit)));
            assertEq(okEager, okLazy, "same bid accepted in one world only");
            _check();
        }
        for (uint256 b; b < 3 * uint256(K); ++b) {
            vm.roll(vm.getBlockNumber() + 1);
            eager.updateStateMachine(ID);
        }
        lazy.updateStateMachine(ID);
        _check();
    }

    function _check() internal {
        AmAmm.Bid memory te = eager.getBid(ID, true);
        AmAmm.Bid memory tl = lazy.getBid(ID, true);
        AmAmm.Bid memory ne = eager.getBid(ID, false);
        AmAmm.Bid memory nl = lazy.getBid(ID, false);
        assertEq(te.manager, tl.manager, "seat holder");
        assertEq(te.rent, tl.rent, "seat rent");
        assertEq(te.deposit, tl.deposit, "seat deposit");
        assertEq(ne.manager, nl.manager, "queued bidder");
        assertEq(ne.deposit, nl.deposit, "queued deposit");
        lazy.updateStateMachine(ID);
        assertEq(eager.totalRentCharged(), lazy.totalRentCharged(), "rent charged");
        for (uint256 i; i < 3; ++i) {
            assertEq(eager.refundOf(bidders[i], ID), lazy.refundOf(bidders[i], ID), "refunds");
        }
        // solvency: everything the auction holds is a deposit, a refund or charged rent
        for (uint256 i; i < 2; ++i) {
            AmAmmHarness h = i == 0 ? eager : lazy;
            assertEq(
                token.balanceOf(address(h)),
                h.topBid(ID).deposit + h.nextBid(ID).deposit + _refundSum(h) + h.totalRentCharged(),
                "auction balance"
            );
        }
    }

    function _refundSum(AmAmmHarness h) internal view returns (uint256 s) {
        for (uint256 i; i < 3; ++i) s += h.refundOf(bidders[i], ID);
    }

    // -----------------------------------------------------------------
    // BidDog rules, one by one
    // -----------------------------------------------------------------

    function test_bidTakesSeatExactlyKBlocksLater() public {
        _bid(eager, bidders[0], 1000, 1000 * K);
        vm.roll(vm.getBlockNumber() + K - 1);
        assertEq(eager.getBid(ID, true).manager, address(0));
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(eager.getBid(ID, true).manager, bidders[0]);
    }

    function test_raiseMustBeatQueueByTenPercent() public {
        _bid(eager, bidders[0], 1000, 1000 * K);
        vm.prank(bidders[1]);
        vm.expectRevert(AmAmm.AmAmm__InvalidBid.selector);
        eager.bid(ID, bidders[1], 3000, 1100, 1100 * K);
        _bid(eager, bidders[1], 1101, 1101 * K);
        assertEq(eager.refundOf(bidders[0], ID), 1000 * uint256(K), "outbid queue refunded in full");
    }

    function test_depositRulesAndFeeCap() public {
        vm.startPrank(bidders[0]);
        vm.expectRevert(AmAmm.AmAmm__InvalidBid.selector);
        eager.bid(ID, bidders[0], 3000, 1000, 1000 * K - 1000); // under K blocks of rent
