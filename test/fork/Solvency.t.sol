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
    }

    function collect(uint256 who) external settle {
        address lp = lps[who % 3];
        vm.prank(lp);
        hook.collect(key, lp);
    }

    function swap(uint256 who, bool zeroForOne, uint256 amount) external settle {
        if (pm.getLiquidity(id) == 0) return;
        uint256 a = zeroForOne ? bound(amount, 1e15, 300e18) : bound(amount, 1e5, 40_000e6);
        vm.prank(traders[who % 2]);
        router.swap(
            key,
            SwapParams(zeroForOne, -int256(a), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function agentSwap(uint256 who, bool zeroForOne, uint256 amount) external settle {
        if (pm.getLiquidity(id) == 0) return;
        uint256 a = zeroForOne ? bound(amount, 1e15, 100e18) : bound(amount, 1e5, 15_000e6);
        agents[who % 3].swap(key, zeroForOne, -int256(a), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    function bid(uint256 who, uint256 rentSeed, uint256 blocksSeed, uint24 fee) external settle {
        AmAmm.Bid memory next = hook.getBid(id, false);
        AmAmm.Bid memory top = hook.getBid(id, true);
        uint256 base = next.rent > top.rent ? next.rent : top.rent;
        if (base < 2000) base = 2000;
        uint128 rent = uint128(base * bound(rentSeed, 80, 200) / 100);
        uint128 deposit = rent * K * uint128(bound(blocksSeed, 1, 3));
        try agents[who % 3].bid(id, uint24(bound(fee, 0, 10_000)), rent, deposit) {
            ++bids;
        } catch {}
    }

    function depositMore(uint256 who, bool top, uint256 blocks) external settle {
        AmAmm.Bid memory b = hook.getBid(id, top);
        if (b.manager != address(agents[who % 3])) return;
        agents[who % 3].depositIntoBid(id, b.rent * uint128(bound(blocks, 1, 2000)), top);
    }

    function withdraw(uint256 who, bool top, uint256 blocks) external settle {
        AmAmm.Bid memory b = hook.getBid(id, top);
        if (b.manager != address(agents[who % 3])) return;
        try agents[who % 3].withdrawFromBid(id, b.rent * uint128(bound(blocks, 1, 2 * uint256(K))), top) {} catch {}
    }

    function setFee(uint256 who, uint24 fee, bool top) external settle {
        try agents[who % 3].setFee(id, uint24(bound(fee, 0, 10_000)), top) {} catch {}
    }

    function claim(uint256 who) external settle {
        SeatAgent a = agents[who % 3];
        a.claimRefund(id);
        a.claimFees(key.currency0);
        a.claimFees(key.currency1);
    }

    function roll(uint256 blocks) external settle {
        vm.roll(vm.getBlockNumber() + bound(blocks, 1, 2 * uint256(K)));
    }

    function crank() external settle {
        try hook.crankBurn() {
            ++burns;
        } catch {}
    }
}

contract SolvencyForkTest is Fixture {
    using StateLibrary for IPoolManager;

    Handler handler;

    function setUp() public override {
        super.setUp();
        address[3] memory lps = [lp1, lp2, makeAddr("lp3")];
        _fund(lps[2], 5_000_000e6, 10_000e18);
        vm.startPrank(lps[2]);
        ERC20(USDG).approve(address(hook), type(uint256).max);
        ERC20(SPCX).approve(address(hook), type(uint256).max);
        vm.stopPrank();
        handler = new Handler(hook, PM, router, key, id, lps, [trader, rivalOwner]);
        vm.startPrank(rivalOwner);
        ERC20(USDG).approve(address(router), type(uint256).max);
        ERC20(SPCX).approve(address(router), type(uint256).max);
        vm.stopPrank();
        for (uint256 i; i < 3; ++i) _fund(address(handler.agents(i)), 50_000_000e6, 2_000e18);
        // start with liquidity so swaps and bids have something to act on
        _add(lp1, 2e16);
        targetContract(address(handler));
        // fixed callers: every account the fuzzer touches is one the fork already holds
        targetSender(lp1);
    }

    /// @notice Everything the hook owes in USDG and SPCX is in its balance.
    function invariant_solvent() public view {
        uint256 owedUsdg = hook.burnBucket();
        uint256 owedSpcx;
        AmAmm.Bid memory top = hook.getBid(id, true);
        AmAmm.Bid memory next = hook.getBid(id, false);
        owedUsdg += top.deposit + next.deposit;
        for (uint256 i; i < 3; ++i) {
            address a = address(handler.agents(i));
            owedUsdg += hook.getRefund(a, id) + hook.getFees(a, key.currency1);
            owedSpcx += hook.getFees(a, key.currency0);
            (uint256 o0, uint256 o1) = hook.owed(key, handler.lps(i));
            owedSpcx += o0;
            owedUsdg += o1;
        }
        uint256 balUsdg = _usdg(address(hook));
        uint256 balSpcx = _spcx(address(hook));
        assertGe(balUsdg, owedUsdg, "USDG short");
        assertGe(balSpcx, owedSpcx, "SPCX short");
        // what is left over is rounding dust only
        assertLe(balUsdg - owedUsdg, handler.calls() + 10, "USDG dust");
        assertLe(balSpcx - owedSpcx, handler.calls() * 1e6 + 10, "SPCX dust");
    }

    /// @notice The hook's position is the whole pool and equals the sum of the LP books.
    function invariant_booksMatchThePool() public view {
        uint128 sum;
        for (uint256 i; i < 3; ++i) {
            (uint128 l,,,,,) = hook.positions(id, handler.lps(i));
            sum += l;
        }
        (,, uint128 total,,,) = hook.pools(id);
        assertEq(total, sum);
        assertEq(PM.getLiquidity(id), total);
    }

    function afterInvariant() external view {
        assertGt(handler.calls(), 0);
        console2.log("calls, bids, seat changes", handler.calls(), handler.bids(), handler.seatChanges());
        console2.log("calls with a seat held, burns", handler.heldCalls(), handler.burns());
    }
}
