// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";

/// @dev Arbitrum precompile. On Robinhood Chain (an Arbitrum Orbit chain) `block.number` is the
/// Ethereum block number (12 s); the chain's own 0.1 s block number comes from here.
interface ArbSys {
    function arbBlockNumber() external view returns (uint256);
}

/// @title AmAmm
/// @notice The manager-seat auction of the am-AMM paper (Adams, Moallemi, Reynolds, Robinson,
/// arXiv 2403.03367), ported from Bunni's BidDog (github.com/Bunniapp/biddog, AGPL-3.0).
/// The state machine (states A to D, promotion after K blocks, 10% raise rule, D >= R * K) is
/// BidDog's line for line. Changes: the bid payload is a swap fee that takes effect from the next
/// block (paper: "adjust the swap fee for the next block"), the caller is msg.sender (no
/// multicaller), charged rent goes to `_chargeRent` instead of being burned as LP tokens, and a
/// queued bid that waits for a run-dry seat starts at the exact block the deposit ran out.
abstract contract AmAmm {
    /// @dev `fee` applies from block index `feeBlockIdx + 1`; until then `prevFee` applies.
    /// A promoted bid has `feeBlockIdx == 0`, so its own fee applies at once.
    struct Bid {
        address manager;
        uint48 blockIdx; // block index of submission (next bid) or of the last rent charge (top bid)
        uint24 fee; // swap fee in pips (1e6 = 100%)
        uint24 prevFee;
        uint128 rent; // quote units per block
        uint128 deposit; // quote units, a multiple of rent
        uint48 feeBlockIdx;
    }

    error AmAmm__InvalidBid();
    error AmAmm__InvalidFee();
    error AmAmm__Unauthorized();
    error AmAmm__InvalidDepositAmount();
    error AmAmm__BidLocked();
    error AmAmm__NotEnabled();

    event SubmitBid(
        PoolId indexed id, address indexed manager, uint48 blockIdx, uint24 fee, uint128 rent, uint128 deposit
    );
    event DepositIntoBid(PoolId indexed id, address indexed manager, bool isTopBid, uint128 amount);
    event WithdrawFromBid(PoolId indexed id, address indexed manager, address recipient, bool isTopBid, uint128 amount);
    event ClaimRefund(PoolId indexed id, address indexed manager, address recipient, uint256 refund);
    event ClaimFees(Currency indexed currency, address indexed manager, address recipient, uint256 fees);
    event SetFee(PoolId indexed id, address indexed manager, bool isTopBid, uint24 fee);

    /// @notice Blocks between a bid landing and the earliest block it can hold the seat.
    /// BidDog's 7,200 blocks; at Robinhood Chain's 0.1 s blocks that is 12 minutes.
    uint48 public constant K = 7200;
    /// @notice A new bid must beat the queued bid, and a queued bid must beat the seat holder,
    /// by more than 10% to matter (BidDog's MIN_BID_MULTIPLIER).
    uint256 public constant MIN_BID_MULTIPLIER = 1.1e18;
    /// @notice Highest swap fee a seat holder can set, in pips (1%).
    uint24 public constant FEE_CAP = 10_000;

    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    uint256 internal immutable _deploymentBlockNumber;

    mapping(PoolId => Bid) internal _topBids;
    mapping(PoolId => Bid) internal _nextBids;
    mapping(PoolId => uint48) internal _lastUpdatedBlockIdx;
    mapping(Currency => uint256) internal _totalFees;
    mapping(address => mapping(PoolId => uint256)) internal _refunds;
    mapping(address => mapping(Currency => uint256)) internal _fees;

    constructor() {
        _deploymentBlockNumber = _blockNumber();
    }

    modifier onlyAmAmmEnabled(PoolId id) {
        if (!_amAmmEnabled(id)) revert AmAmm__NotEnabled();
        _;
    }

    // ---------------------------------------------------------------------
    // Bidder actions
    // ---------------------------------------------------------------------
