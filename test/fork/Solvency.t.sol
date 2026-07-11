// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

import {AmAmm} from "../../src/AmAmm.sol";
import {Landlord} from "../../src/Landlord.sol";
import {Fixture, SeatAgent} from "../utils/Fixture.sol";

/// @notice Random LPs, traders and seat bidders on the real PoolManager. Every call ends with the
/// state machine settled to the current block, so stored balances are the live ones.
contract Handler is Test {
    using StateLibrary for IPoolManager;

    Landlord immutable hook;
    IPoolManager immutable pm;
    PoolSwapTest immutable router;
    PoolKey key;
    PoolId immutable id;
    address[3] public lps;
    address[2] traders;
    SeatAgent[3] public agents;
    uint48 immutable K;

    uint256 public calls;
    uint256 public seatChanges;
    uint256 public burns;

    constructor(Landlord hook_, IPoolManager pm_, PoolSwapTest router_, PoolKey memory key_, PoolId id_, address[3] memory lps_, address[2] memory traders_) {
        hook = hook_;
        pm = pm_;
        router = router_;
        key = key_;
        id = id_;
        lps = lps_;
        traders = traders_;
        K = hook_.K();
        for (uint256 i; i < 3; ++i) agents[i] = new SeatAgent(pm_, hook_);
    }

    uint256 public bids;
    uint256 public heldCalls; // calls that ended with a seat held

    modifier settle() {
        ++calls;
        address before = hook.getBid(id, true).manager;
        _;
        hook.updateStateMachine(id);
        address afterCall = hook.getBid(id, true).manager;
        if (afterCall != before) ++seatChanges;
        if (afterCall != address(0)) ++heldCalls;
    }

    function add(uint256 who, uint256 liq) external settle {
        uint128 l = uint128(bound(liq, 1e13, 2e16));
        vm.prank(lps[who % 3]);
        try hook.addLiquidity(key, l, type(uint256).max, type(uint256).max, 0, type(uint160).max) {} catch {}
    }

    function remove(uint256 who, uint256 frac) external settle {
        address lp = lps[who % 3];
        (uint128 l,,,,,) = hook.positions(id, lp);
        uint128 amount = uint128(uint256(l) * bound(frac, 1, 100) / 100);
        if (amount == 0) return;
        vm.prank(lp);
        hook.removeLiquidity(key, amount, 0, 0, 0, type(uint160).max);
