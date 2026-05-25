// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {Landlord} from "./Landlord.sol";

/// @title SeatDesk
/// @notice The contract a wallet holds a LANDLORD seat with. The hook waives the swap fee only when
/// the PoolManager's caller is the seat holder; a wallet cannot call the PoolManager (it needs an
/// unlock callback) and a router call makes the router the caller. So the wallet bids with this desk
/// as `manager`, swaps through it fee-free and runs the seat through it.
/// @dev Owner only, and only the calls a seat holder needs: no arbitrary call, so a signed desk
/// transaction can never move the owner's approved tokens anywhere but into its own swap. The desk
/// holds nothing between calls: swap input is pulled from the owner and output paid to the owner in
/// the same callback, top-ups pass straight to the hook, and every hook payout names the owner.
contract SeatDesk is IUnlockCallback {
    using SafeTransferLib for ERC20;
    using SafeCast for int128;

    error NotOwner();
    error NotPoolManager();
    error NotLandlordPool();
    error TooLittleReceived();
    error OverPaid();

    IPoolManager public immutable poolManager;
    Landlord public immutable hook;
    address public immutable owner;

    constructor(IPoolManager poolManager_, Landlord hook_, address owner_) {
        poolManager = poolManager_;
        hook = hook_;
        owner = owner_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ---------------------------------------------------------------------
    // Running the seat
    // ---------------------------------------------------------------------

    function setFee(PoolId id, uint24 fee, bool isTopBid) external onlyOwner {
        hook.setBidFee(id, fee, isTopBid);
    }

    /// @notice Add to this desk's bid: USDG comes from the owner and goes straight into the hook.
    function topUp(PoolId id, uint128 amount, bool isTopBid) external onlyOwner {
        ERC20 quote = ERC20(Currency.unwrap(hook.quote()));
        quote.safeTransferFrom(msg.sender, address(this), amount);
        quote.safeApprove(address(hook), amount);
        hook.depositIntoBid(id, amount, isTopBid);
    }

    function withdraw(PoolId id, uint128 amount, bool isTopBid) external onlyOwner {
        hook.withdrawFromBid(id, amount, owner, isTopBid);
    }

    function claimRefund(PoolId id) external onlyOwner returns (uint256) {
        return hook.claimRefund(id, owner);
    }

    function claimFees(Currency currency) external onlyOwner returns (uint256) {
        return hook.claimFees(currency, owner);
    }

    // ---------------------------------------------------------------------
    // Fee-free swap
    // ---------------------------------------------------------------------

    /// @notice Exact-in swap straight on the PoolManager, from and to the owner's wallet (the owner
    /// approves this desk for the input token). Only LANDLORD pools: a pool with another hook could
    /// charge the swapper more than `amountIn` through a hook delta, and the desk pays from the
    /// owner's approval.
    function swap(PoolKey calldata key, bool zeroForOne, uint128 amountIn, uint256 minOut)
        external
        onlyOwner
        returns (uint256 out)
    {
        if (address(key.hooks) != address(hook)) revert NotLandlordPool();
        out = abi.decode(poolManager.unlock(abi.encode(key, zeroForOne, amountIn)), (uint256));
        if (out < minOut) revert TooLittleReceived();
    }

    /// @dev Reached only from `swap`: the PoolManager calls back the contract that unlocked it.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, bool zeroForOne, uint128 amountIn) = abi.decode(data, (PoolKey, bool, uint128));
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(uint256(amountIn)),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        (Currency cin, Currency cout) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        uint256 paid = (zeroForOne ? -delta.amount0() : -delta.amount1()).toUint128();
        uint256 got = (zeroForOne ? delta.amount1() : delta.amount0()).toUint128();
        if (paid > amountIn) revert OverPaid();

        poolManager.sync(cin);
        ERC20(Currency.unwrap(cin)).safeTransferFrom(owner, address(poolManager), paid);
        poolManager.settle();
        poolManager.take(cout, owner, got);
        return abi.encode(got);
    }
}

/// @notice One desk per wallet, at an address the app can compute before it exists. Deployed once,
/// next to the hook.
contract SeatDeskFactory {
    event DeskOpened(address indexed owner, address desk);

    IPoolManager public immutable poolManager;
    Landlord public immutable hook;
    mapping(address => address) public deskOf;

    constructor(IPoolManager poolManager_, Landlord hook_) {
        poolManager = poolManager_;
        hook = hook_;
    }

    /// @notice Opens the caller's desk, or returns it if it exists. Nobody can open one for someone else.
    function open() external returns (address desk) {
        desk = deskOf[msg.sender];
        if (desk != address(0)) return desk;
        desk = address(new SeatDesk{salt: bytes32(uint256(uint160(msg.sender)))}(poolManager, hook, msg.sender));
        deskOf[msg.sender] = desk;
        emit DeskOpened(msg.sender, desk);
    }
}
