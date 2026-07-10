// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

import {AmAmm} from "../../src/AmAmm.sol";
import {SeatDesk, SeatDeskFactory} from "../../src/SeatDesk.sol";
import {Fixture} from "../utils/Fixture.sol";

/// @notice A wallet holding a seat through its desk, on the real PoolManager with SPCX and USDG.
contract SeatDeskForkTest is Fixture {
    uint128 constant L = 5e16;
    uint128 constant RENT = 5000;
    uint48 K;
    SeatDeskFactory factory;
    SeatDesk desk;
    address wallet = makeAddr("wallet");
    address stranger = makeAddr("stranger");

    function setUp() public override {
        super.setUp();
        K = hook.K();
        factory = new SeatDeskFactory(PM, hook);
        _fund(wallet, 5_000_000e6, 10_000e18);
        _add(lp1, L);
        vm.prank(wallet);
        desk = SeatDesk(factory.open());
        vm.startPrank(wallet);
        ERC20(USDG).approve(address(hook), type(uint256).max); // the wallet pays the bid
        ERC20(USDG).approve(address(desk), type(uint256).max); // desk swaps and top-ups
        ERC20(SPCX).approve(address(desk), type(uint256).max);
        hook.bid(id, address(desk), 3000, RENT, RENT * K * 4);
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + K);
        hook.updateStateMachine(id);
        require(hook.getBid(id, true).manager == address(desk), "desk holds the seat");
    }

    function test_oneDeskPerWalletAtAPredictableAddress() public {
        vm.prank(wallet);
        assertEq(factory.open(), address(desk), "second open returns the same desk");
        assertEq(factory.deskOf(wallet), address(desk));
        bytes32 initHash = keccak256(abi.encodePacked(type(SeatDesk).creationCode, abi.encode(PM, hook, wallet)));
        assertEq(address(desk), vm.computeCreate2Address(bytes32(uint256(uint160(wallet))), initHash, address(factory)));
        assertEq(desk.owner(), wallet);
        vm.prank(stranger);
        assertTrue(factory.open() != address(desk), "a stranger gets its own desk, never someone else's");
    }

    function test_onlyTheOwnerRunsTheDesk() public {
        vm.startPrank(stranger);
        vm.expectRevert(SeatDesk.NotOwner.selector);
        desk.setFee(id, 1, true);
        vm.expectRevert(SeatDesk.NotOwner.selector);
        desk.topUp(id, RENT, true);
        vm.expectRevert(SeatDesk.NotOwner.selector);
        desk.withdraw(id, RENT, true);
        vm.expectRevert(SeatDesk.NotOwner.selector);
        desk.claimRefund(id);
        vm.expectRevert(SeatDesk.NotOwner.selector);
        desk.claimFees(key.currency0);
        vm.expectRevert(SeatDesk.NotOwner.selector);
        desk.swap(key, false, 1e6, 0);
        vm.expectRevert(SeatDesk.NotPoolManager.selector);
        desk.unlockCallback(abi.encode(key, false, uint128(1e6)));
        vm.stopPrank();
    }

    function test_ownerSwapsFeeFreeAndDeskHoldsNothing() public {
        uint256 s0 = _spcx(wallet);
        uint256 u0 = _usdg(wallet);
        vm.prank(wallet);
        uint256 out = desk.swap(key, false, 10_000e6, 0);
        assertEq(_spcx(wallet) - s0, out, "output paid to the wallet");
        assertEq(u0 - _usdg(wallet), 10_000e6, "input pulled from the wallet");
        assertEq(hook.getFees(address(desk), key.currency0), 0, "no fee booked on the holder's own swap");
        _empty();

        // the same trade by anyone else through a router pays the 0.3% seat fee to the desk
        vm.prank(wallet);
        desk.swap(key, true, uint128(out), 0); // put the price back
        uint256 traderOut = uint256(int256(_swap(trader, false, 10_000e6).amount0()));
        assertApproxEqRel(out - traderOut, out * 3000 / 1_000_000, 1e14);
        assertGt(hook.getFees(address(desk), key.currency0), 0);
    }

    function test_swapRefusesOtherPoolsAndHonoursMinOut() public {
        PoolKey memory plain = PoolKey(key.currency0, key.currency1, 3000, 60, hook.burnPoolKey().hooks);
        vm.startPrank(wallet);
        vm.expectRevert(SeatDesk.NotLandlordPool.selector);
        desk.swap(plain, false, 1e6, 0);
        vm.expectRevert(SeatDesk.TooLittleReceived.selector);
        desk.swap(key, false, 1_000e6, type(uint256).max);
        vm.stopPrank();
    }

    function test_runTheSeatThroughTheDesk() public {
        vm.startPrank(wallet);
        desk.setFee(id, 7000, true);
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(hook.currentFee(id), 7000);

        uint128 before = hook.getBid(id, true).deposit;
        desk.topUp(id, RENT * 100, true);
        assertEq(hook.getBid(id, true).deposit, before + RENT * 100, "top-up lands in the bid");
        assertEq(ERC20(USDG).allowance(address(desk), address(hook)), 0, "no approval left behind");
        _empty();

        uint256 u0 = _usdg(wallet);
        desk.withdraw(id, RENT * K, true);
        assertEq(_usdg(wallet) - u0, RENT * K, "withdrawal paid to the wallet");
        vm.expectRevert(AmAmm.AmAmm__BidLocked.selector);
        desk.withdraw(id, RENT * K * 3, true); // would leave under K blocks
        vm.stopPrank();

        _swap(trader, false, 10_000e6);
        uint256 booked = hook.getFees(address(desk), key.currency0);
        uint256 s0 = _spcx(wallet);
        vm.prank(wallet);
        desk.claimFees(key.currency0);
        assertEq(_spcx(wallet) - s0, booked, "fees paid to the wallet");
        _empty();
    }

    function test_refundAfterBeingOutbidGoesToTheWallet() public {
        vm.prank(rivalOwner);
        hook.bid(id, rivalOwner, 3000, RENT * 2, RENT * 2 * K);
        vm.roll(vm.getBlockNumber() + K);
        hook.updateStateMachine(id);
        uint256 refund = hook.getRefund(address(desk), id);
        assertEq(refund, uint256(RENT) * K * 3, "4K deposit less the K blocks it kept the seat after the rival bid");
        uint256 u0 = _usdg(wallet);
        vm.prank(wallet);
        assertEq(desk.claimRefund(id), refund);
        assertEq(_usdg(wallet) - u0, refund);
        _empty();
    }

    function _empty() internal view {
        assertEq(_usdg(address(desk)), 0, "desk holds no USDG");
        assertEq(_spcx(address(desk)), 0, "desk holds no SPCX");
    }
}
