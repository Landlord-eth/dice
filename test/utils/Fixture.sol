// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

import {Landlord} from "../../src/Landlord.sol";
import {HookAddress} from "../../script/HookAddress.sol";

/// @notice A seat holder's bot: the contract that bids is the contract that swaps, so its swaps
/// reach the hook with `sender == manager` and pay no fee.
contract SeatAgent is IUnlockCallback {
    IPoolManager public immutable pm;
    Landlord public immutable hook;
    address public immutable owner;

    constructor(IPoolManager pm_, Landlord hook_) {
        pm = pm_;
        hook = hook_;
        owner = msg.sender;
        ERC20(Currency.unwrap(hook_.quote())).approve(address(hook_), type(uint256).max);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "owner");
        _;
    }

    function bid(PoolId id, uint24 fee, uint128 rent, uint128 deposit) external onlyOwner {
        hook.bid(id, address(this), fee, rent, deposit);
    }

    function depositIntoBid(PoolId id, uint128 amount, bool top) external onlyOwner {
        hook.depositIntoBid(id, amount, top);
    }

    function withdrawFromBid(PoolId id, uint128 amount, bool top) external onlyOwner {
        hook.withdrawFromBid(id, amount, owner, top);
    }

    function setFee(PoolId id, uint24 fee, bool top) external onlyOwner {
        hook.setBidFee(id, fee, top);
    }

    function claimRefund(PoolId id) external onlyOwner returns (uint256) {
        return hook.claimRefund(id, owner);
    }

    function claimFees(Currency c) external onlyOwner returns (uint256) {
        return hook.claimFees(c, owner);
    }

    /// @notice Exact-in swap (amountSpecified < 0) or exact-out (> 0) with a price limit.
    function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 limit)
        external
        onlyOwner
        returns (BalanceDelta)
    {
        return abi.decode(pm.unlock(abi.encode(key, zeroForOne, amountSpecified, limit)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "pm");
        (PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 limit) =
            abi.decode(data, (PoolKey, bool, int256, uint160));
        BalanceDelta d = pm.swap(key, SwapParams(zeroForOne, amountSpecified, limit), "");
        _settle(key.currency0, d.amount0());
        _settle(key.currency1, d.amount1());
        return abi.encode(d);
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

/// @notice Stands in for the ArbSys precompile, which anvil does not have. On the fork the EVM
/// block number is the chain's own block number, which is what ArbSys returns on the real chain.
contract MockArbSys {
    function arbBlockNumber() external view returns (uint256) {
        return block.number;
    }
}

/// @notice Fork of Robinhood Chain: the real Uniswap v4 PoolManager, the real SPCX stock token and
/// USDG. The LANDLORD token does not exist yet, so a stand-in ERC20 and a real plain v4 pool for it
/// on the same PoolManager play the burn side.
abstract contract Fixture is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant SPCX = 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa;
    /// @dev The busiest SPCX/USDG v4 pool on Robinhood Chain; the fixture opens at its price.
    PoolId constant REF_POOL = PoolId.wrap(0x1f5bf0b4df6d26da68a30535727acaf41634443b6421bcecd8ac1d455b2f91d6);

    Landlord hook;
    MockERC20 standIn;
    PoolKey key; // SPCX/USDG LANDLORD pool
    PoolId id;
    PoolKey burnKey;
    PoolSwapTest router;
    PoolModifyLiquidityTest liqRouter;
    uint160 startPrice;

    address lp1 = makeAddr("lp1");
    address lp2 = makeAddr("lp2");
    address trader = makeAddr("trader");
    address agentOwner = makeAddr("agentOwner");
    address rivalOwner = makeAddr("rivalOwner");

    function setUp() public virtual {
        vm.createSelectFork(vm.envOr("FORK_URL", string("hood")), vm.envUint("FORK_BLOCK"));

        vm.etch(address(100), type(MockArbSys).runtimeCode);
        router = new PoolSwapTest(PM);
        liqRouter = new PoolModifyLiquidityTest(PM);

        standIn = new MockERC20("LANDLORD stand-in", "LLDX", 18);
        burnKey = _sorted(USDG, address(standIn), 3000, 60, address(0));
        // stand-in at $0.01: 1 LLDX (1e18) = 0.01 USDG (1e4) -> raw price token1/token0
        PM.initialize(burnKey, _sqrtPrice(burnKey, address(standIn), 1e4, 1e18));
        _fund(address(this), 10_000_000e6, 0);
        standIn.mint(address(this), 1e30);
        ERC20(USDG).approve(address(liqRouter), type(uint256).max);
        standIn.approve(address(liqRouter), type(uint256).max);
        liqRouter.modifyLiquidity(
            burnKey,
            ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 1e17, bytes32(0)),
            ""
        );

        // a fixed flagged address keeps every pool id, and so the cached fork state, the same across
        // code changes; test_deploysThroughCreate2 covers the real salt-mined deployment
        address at = address(
            (uint160(uint256(keccak256("LANDLORD"))) & ~Hooks.ALL_HOOK_MASK) | HookAddress.FLAGS
        );
        deployCodeTo(
            "Landlord.sol:Landlord", abi.encode(PM, Currency.wrap(USDG), Currency.wrap(address(standIn)), burnKey), at
        );
        hook = Landlord(at);

        key = _sorted(SPCX, USDG, 0, 60, address(hook));
        id = key.toId();
        (startPrice,,,) = PM.getSlot0(REF_POOL);
        PM.initialize(key, startPrice);
        _touchBitmap(id);
        _touchBitmap(burnKey.toId());

        address[5] memory actors = [lp1, lp2, trader, agentOwner, rivalOwner];
        for (uint256 i; i < actors.length; ++i) {
            _fund(actors[i], 5_000_000e6, 10_000e18);
            vm.startPrank(actors[i]);
            ERC20(USDG).approve(address(hook), type(uint256).max);
            ERC20(SPCX).approve(address(hook), type(uint256).max);
            ERC20(USDG).approve(address(router), type(uint256).max);
            ERC20(SPCX).approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ---------------------------------------------------------------------

    /// @dev Reads every tick-bitmap word of a tick-spacing-60 pool once, so a fresh run caches the
    /// words any later swap can reach and the pinned replay never asks the RPC for state.
    function _touchBitmap(PoolId pid) internal view {
        for (int16 w = -61; w <= 61; ++w) PM.getTickBitmap(pid, w);
    }

    function _fund(address who, uint256 usdg, uint256 spcx) internal {
        if (usdg != 0) deal(USDG, who, ERC20(USDG).balanceOf(who) + usdg);
        if (spcx != 0) deal(SPCX, who, ERC20(SPCX).balanceOf(who) + spcx);
    }

    function _sorted(address a, address b, uint24 fee, int24 spacing, address hooks) internal pure returns (PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, spacing, IHooks(hooks));
    }

    /// @dev sqrtPriceX96 for "amountBase of base is worth amountOther of the other token".
    function _sqrtPrice(PoolKey memory k, address base, uint256 amountOther, uint256 amountBase)
        internal
        pure
        returns (uint160)
    {
        bool baseIs0 = Currency.unwrap(k.currency0) == base;
        (uint256 num, uint256 den) = baseIs0 ? (amountOther, amountBase) : (amountBase, amountOther);
        return uint160(_sqrt((num << 192) / den));
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = (x >> 1) + 1;
        while (y < z) (z, y) = (y, (x / y + y) >> 1);
    }

    function _add(address who, uint128 liquidity) internal returns (uint256 a0, uint256 a1) {
        vm.prank(who);
        (a0, a1) = hook.addLiquidity(key, liquidity, type(uint256).max, type(uint256).max, 0, type(uint160).max);
    }

    function _remove(address who, uint128 liquidity) internal returns (uint256 a0, uint256 a1) {
        vm.prank(who);
        (a0, a1) = hook.removeLiquidity(key, liquidity, 0, 0, 0, type(uint160).max);
    }

    /// @dev Exact-in swap by `who` through the public test router (sender = router, so it pays the fee).
    function _swap(address who, bool zeroForOne, uint256 amountIn) internal returns (BalanceDelta d) {
        vm.prank(who);
        d = router.swap(
            key,
            SwapParams(zeroForOne, -int256(amountIn), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function _agent(address owner_) internal returns (SeatAgent a) {
        vm.prank(owner_);
        a = new SeatAgent(PM, hook);
        _fund(address(a), 1_000_000e6, 1_000e18);
    }

    function _usdgIs0() internal view returns (bool) {
        return Currency.unwrap(key.currency0) == USDG;
    }

    function _usdg(address who) internal view returns (uint256) {
        return ERC20(USDG).balanceOf(who);
    }

    function _spcx(address who) internal view returns (uint256) {
        return ERC20(SPCX).balanceOf(who);
    }
}
