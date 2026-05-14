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
    // ---------------------------------------------------------------------

    /// @notice The bid as it stands at the current block (rent charged, promotions applied).
    function getBid(PoolId id, bool isTopBid) external view returns (Bid memory) {
        (Bid memory topBid, Bid memory nextBid) = _updateAmAmmView(id);
        return isTopBid ? topBid : nextBid;
    }

    /// @notice Robinhood Chain block at deployment; bid `blockIdx` values count blocks from here.
    function deploymentBlockNumber() external view returns (uint256) {
        return _deploymentBlockNumber;
    }

    function getRefund(address manager, PoolId id) external view returns (uint256) {
        return _refunds[manager][id];
    }

    function getFees(address manager, Currency currency) external view returns (uint256) {
        return _fees[manager][currency];
    }

    // ---------------------------------------------------------------------
    // Hooks for the pool contract
    // ---------------------------------------------------------------------

    function _amAmmEnabled(PoolId id) internal view virtual returns (bool);

    /// @dev Reserve rent for a pool at bid time, in quote units per block.
    function _minRent(PoolId id) internal view virtual returns (uint128);

    /// @dev Rent charged from the seat holder's deposit, already held by this contract.
    function _chargeRent(PoolId id, uint256 amount) internal virtual;

    function _pullBidToken(address from, uint256 amount) internal virtual;

    function _pushBidToken(address to, uint256 amount) internal virtual;

    function _transferFeeToken(Currency currency, address to, uint256 amount) internal virtual;

    function _accrueFees(address manager, Currency currency, uint256 amount) internal {
        _fees[manager][currency] += amount;
        _totalFees[currency] += amount;
    }

    // ---------------------------------------------------------------------
    // State machine
    // ---------------------------------------------------------------------

    /// @dev Robinhood Chain's own block number (BidDog's BlockNumberLib does the same on Arbitrum One).
    function _blockNumber() internal view returns (uint256) {
        return block.chainid == ROBINHOOD_CHAIN_ID ? ArbSys(address(100)).arbBlockNumber() : block.number;
    }

    function _blockIdx() internal view returns (uint48) {
        // 2^48 blocks is 890,000 years at 0.1 s
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint48(_blockNumber() - _deploymentBlockNumber);
    }

    function _feeAt(Bid memory b, uint48 idx) internal pure returns (uint24) {
        return idx > b.feeBlockIdx ? b.fee : b.prevFee;
    }

    function _mulWad(uint128 x, uint256 y) private pure returns (uint256) {
        return uint256(x) * y / 1e18;
    }

    /// @dev Charges rent and applies promotions up to the current block. Idempotent within a block.
    function _updateAmAmmWrite(PoolId id) internal {
        uint48 currentBlockIdx = _blockIdx();
        if (_lastUpdatedBlockIdx[id] == currentBlockIdx) return;

        Bid memory topBid = _topBids[id];
        Bid memory nextBid = _nextBids[id];
        bool updatedTopBid;
        bool updatedNextBid;
        uint256 rentCharged;

        while (true) {
            (
                Bid memory t,
                Bid memory n,
                bool stepUpdatedTop,
                bool stepUpdatedNext,
                uint256 stepRent,
                address refundManager,
                uint256 refundAmount
            ) = _stateTransition(currentBlockIdx, topBid, nextBid);
            if (!stepUpdatedTop && !stepUpdatedNext) break;
            (topBid, nextBid) = (t, n);
            updatedTopBid = updatedTopBid || stepUpdatedTop;
            updatedNextBid = updatedNextBid || stepUpdatedNext;
            rentCharged += stepRent;
            if (refundManager != address(0)) _refunds[refundManager][id] += refundAmount;
        }

        if (updatedTopBid) _topBids[id] = topBid;
        if (updatedNextBid) _nextBids[id] = nextBid;
        _lastUpdatedBlockIdx[id] = currentBlockIdx;

        if (rentCharged != 0) _chargeRent(id, rentCharged);
    }

    function _updateAmAmmView(PoolId id) internal view returns (Bid memory topBid, Bid memory nextBid) {
        uint48 currentBlockIdx = _blockIdx();
        topBid = _topBids[id];
        nextBid = _nextBids[id];
        if (_lastUpdatedBlockIdx[id] == currentBlockIdx) return (topBid, nextBid);

        while (true) {
            (Bid memory t, Bid memory n, bool stepUpdatedTop, bool stepUpdatedNext,,,) =
                _stateTransition(currentBlockIdx, topBid, nextBid);
            if (!stepUpdatedTop && !stepUpdatedNext) break;
            (topBid, nextBid) = (t, n);
        }
    }

    /// @dev One step of BidDog's machine. A: no seat, no queue. B: seat, no queue.
    /// C: no seat, queue. D: seat and queue.
    /// A -bid-> C -K blocks-> B -deposit runs out-> A; B -bid-> D; D -K blocks, queue beats seat by 10%-> B;
    /// D -seat deposit runs out-> C; C and D -higher bid-> same state with the new queue.
    function _stateTransition(uint48 currentBlockIdx, Bid memory topBid, Bid memory nextBid)
        internal
        pure
        returns (
            Bid memory,
            Bid memory,
            bool updatedTopBid,
            bool updatedNextBid,
            uint256 rentCharged,
            address refundManager,
            uint256 refundAmount
        )
    {
        if (nextBid.manager == address(0)) {
            if (topBid.manager != address(0)) {
                // State B: charge rent
                uint256 rentOwed = uint256(currentBlockIdx - topBid.blockIdx) * topBid.rent;
                if (rentOwed >= topBid.deposit) {
                    // B -> A: the deposit ran out
                    rentCharged = topBid.deposit;
                    topBid = _emptyBid();
                    updatedTopBid = true;
                } else if (rentOwed != 0) {
                    rentCharged = rentOwed;
                    // rentOwed < deposit, a uint128
                    // forge-lint: disable-next-line(unsafe-typecast)
                    topBid.deposit -= uint128(rentOwed);
                    topBid.blockIdx = currentBlockIdx;
                    updatedTopBid = true;
                }
            }
        } else if (topBid.manager == address(0)) {
            // State C: promote the queued bid once K blocks have passed
            uint48 nextBidStartBlockIdx = nextBid.blockIdx + K;
            if (currentBlockIdx >= nextBidStartBlockIdx) {
                topBid = nextBid;
                topBid.blockIdx = nextBidStartBlockIdx;
                nextBid = _emptyBid();
                updatedTopBid = true;
                updatedNextBid = true;
            }
        } else {
            // State D: the holder pays until the queued bid's start block, if the queued bid
            // beats it by more than 10%; otherwise the queued bid waits for the seat to run dry
            bool nextBidIsBetter = nextBid.rent > _mulWad(topBid.rent, MIN_BID_MULTIPLIER);
            uint48 nextBidStartBlockIdx = nextBid.blockIdx + K;
            uint48 chargeUntil =
                nextBidIsBetter && nextBidStartBlockIdx < currentBlockIdx ? nextBidStartBlockIdx : currentBlockIdx;
            // chargeUntil >= topBid.blockIdx: a queued bid always lands after the holder's last charge
            uint256 rentOwed = uint256(chargeUntil - topBid.blockIdx) * topBid.rent;
            if (rentOwed >= topBid.deposit) {
                // D -> C: the holder ran dry. The queued bid starts at the later of its own start
                // block and the exact block the deposit ran out (deposits are multiples of rent).
                // BidDog uses the block of this update instead, which leaves the blocks between the
                // run-out and the next touch of the pool unpaid; the exact block makes a lazily
                // updated pool charge the same rent as one updated every block.
                // fits: rentOwed >= deposit means deposit / rent <= blocks elapsed
                // forge-lint: disable-next-line(unsafe-typecast)
                uint48 dryBlockIdx = topBid.blockIdx + uint48(topBid.deposit / topBid.rent);
                rentCharged = topBid.deposit;
                topBid = _emptyBid();
                if (dryBlockIdx >= K && nextBid.blockIdx < dryBlockIdx - K) nextBid.blockIdx = dryBlockIdx - K;
                updatedTopBid = true;
                updatedNextBid = true;
            } else {
                if (rentOwed != 0) {
                    rentCharged = rentOwed;
                    // rentOwed < deposit, a uint128
                    // forge-lint: disable-next-line(unsafe-typecast)
                    topBid.deposit -= uint128(rentOwed);
                    topBid.blockIdx = currentBlockIdx;
                    updatedTopBid = true;
                }
                if (currentBlockIdx >= nextBidStartBlockIdx && nextBidIsBetter) {
                    // D -> B: the queued bid takes the seat at its start block; the holder keeps
                    // the deposit it did not use
                    (refundManager, refundAmount) = (topBid.manager, topBid.deposit);
                    topBid = nextBid;
                    topBid.blockIdx = nextBidStartBlockIdx;
                    nextBid = _emptyBid();
                    updatedTopBid = true;
                    updatedNextBid = true;
                }
            }
        }
        return (topBid, nextBid, updatedTopBid, updatedNextBid, rentCharged, refundManager, refundAmount);
    }

    function _emptyBid() private pure returns (Bid memory) {
        return Bid(address(0), 0, 0, 0, 0, 0, 0);
    }
}
