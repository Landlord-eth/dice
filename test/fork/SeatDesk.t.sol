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
