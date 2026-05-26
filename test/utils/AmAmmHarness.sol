// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {AmAmm} from "../../src/AmAmm.sol";

/// @notice The auction alone, with a plain token, for property tests of the state machine.
contract AmAmmHarness is AmAmm {
    MockERC20 public immutable token;
    uint256 public totalRentCharged;

    constructor(MockERC20 token_) {
        token = token_;
    }

    function _amAmmEnabled(PoolId) internal pure override returns (bool) {
        return true;
    }

    function _minRent(PoolId) internal pure override returns (uint128) {
        return 1;
    }

    function _chargeRent(PoolId, uint256 amount) internal override {
        totalRentCharged += amount;
    }

    function _pullBidToken(address from, uint256 amount) internal override {
        token.transferFrom(from, address(this), amount);
    }

    function _pushBidToken(address to, uint256 amount) internal override {
        token.transfer(to, amount);
    }

    function _transferFeeToken(Currency, address, uint256) internal pure override {}

    function topBid(PoolId id) external view returns (Bid memory) {
        return _topBids[id];
    }

    function nextBid(PoolId id) external view returns (Bid memory) {
        return _nextBids[id];
    }

    function refundOf(address who, PoolId id) external view returns (uint256) {
        return _refunds[who][id];
    }
}
