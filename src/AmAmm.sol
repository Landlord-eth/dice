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

    /// @notice Queue a bid for the seat. It can take over K blocks from now. The deposit is
    /// pulled from msg.sender; `manager` owns the bid, its refunds and its fees.
    function bid(PoolId id, address manager, uint24 fee, uint128 rent, uint128 deposit)
        public
        virtual
        onlyAmAmmEnabled(id)
    {
        _updateAmAmmWrite(id);

        if (
            manager == address(0) || rent <= _mulWad(_nextBids[id].rent, MIN_BID_MULTIPLIER) || rent < _minRent(id)
                || deposit < rent * K || deposit % rent != 0 || fee > FEE_CAP
        ) revert AmAmm__InvalidBid();

        // the outbid queued bid gets its whole deposit back: it never held the seat
        _refunds[_nextBids[id].manager][id] += _nextBids[id].deposit;

        uint48 blockIdx = _blockIdx();
        _nextBids[id] = Bid(manager, blockIdx, fee, fee, rent, deposit, 0);

        _pullBidToken(msg.sender, deposit);

        emit SubmitBid(id, manager, blockIdx, fee, rent, deposit);
    }

    function depositIntoBid(PoolId id, uint128 amount, bool isTopBid) public virtual onlyAmAmmEnabled(id) {
        _updateAmAmmWrite(id);

        Bid storage b = isTopBid ? _topBids[id] : _nextBids[id];
        if (msg.sender != b.manager) revert AmAmm__Unauthorized();
        if (amount % b.rent != 0) revert AmAmm__InvalidDepositAmount();

        b.deposit += amount;

        _pullBidToken(msg.sender, amount);

        emit DepositIntoBid(id, msg.sender, isTopBid, amount);
    }

    /// @notice Take back deposit, leaving at least K blocks of rent: a bid can never stop paying
    /// sooner than K blocks from now (paper: D_top >= R_top * K).
    function withdrawFromBid(PoolId id, uint128 amount, address recipient, bool isTopBid)
        public
        virtual
        onlyAmAmmEnabled(id)
    {
        _updateAmAmmWrite(id);

        Bid storage b = isTopBid ? _topBids[id] : _nextBids[id];
        Bid memory m = b;
        if (msg.sender != m.manager) revert AmAmm__Unauthorized();
        if (amount % m.rent != 0) revert AmAmm__InvalidDepositAmount();
        if (amount > m.deposit || (m.deposit - amount) / m.rent < K) revert AmAmm__BidLocked();

        b.deposit = m.deposit - amount;

        _pushBidToken(recipient, amount);

        emit WithdrawFromBid(id, msg.sender, recipient, isTopBid, amount);
    }

    function claimRefund(PoolId id, address recipient) public virtual onlyAmAmmEnabled(id) returns (uint256 refund) {
        _updateAmAmmWrite(id);

        refund = _refunds[msg.sender][id];
        if (refund == 0) return 0;
        delete _refunds[msg.sender][id];

        _pushBidToken(recipient, refund);

        emit ClaimRefund(id, msg.sender, recipient, refund);
    }

    function claimFees(Currency currency, address recipient) public virtual returns (uint256 fees) {
        fees = _fees[msg.sender][currency];
        if (fees == 0) return 0;
        delete _fees[msg.sender][currency];
        unchecked {
            // _totalFees[currency] is the sum of every manager's fees in that currency
            _totalFees[currency] -= fees;
        }

        _transferFeeToken(currency, recipient, fees);

        emit ClaimFees(currency, msg.sender, recipient, fees);
    }

    /// @notice Change the fee of your bid. On the live seat the new fee applies from the next
    /// block, so a holder cannot reprice a block it has already seen.
    function setBidFee(PoolId id, uint24 fee, bool isTopBid) public virtual onlyAmAmmEnabled(id) {
        _updateAmAmmWrite(id);

        if (fee > FEE_CAP) revert AmAmm__InvalidFee();
        Bid storage b = isTopBid ? _topBids[id] : _nextBids[id];
        if (msg.sender != b.manager) revert AmAmm__Unauthorized();

        uint48 idx = _blockIdx();
        if (isTopBid) {
            b.prevFee = _feeAt(b, idx);
            b.feeBlockIdx = idx;
        } else {
            b.prevFee = fee;
        }
        b.fee = fee;

        emit SetFee(id, msg.sender, isTopBid, fee);
    }

    function updateStateMachine(PoolId id) external {
        _updateAmAmmWrite(id);
    }

    // ---------------------------------------------------------------------
    // Getters
