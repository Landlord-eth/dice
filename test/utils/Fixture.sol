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
