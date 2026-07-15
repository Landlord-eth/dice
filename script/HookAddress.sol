// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.26;

import {Hooks} from "v4-core/libraries/Hooks.sol";

/// @notice Finds a CREATE2 salt that puts the hook at an address whose low bits are its v4
/// permission flags, deploying through the deterministic deployer present on Robinhood Chain.
library HookAddress {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 internal constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG
        | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    function find(bytes memory initCode) internal pure returns (bytes32 salt, address hook) {
        bytes32 codeHash = keccak256(initCode);
        for (uint256 i; i < 1 << 20; ++i) {
            hook = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, bytes32(i), codeHash))))
            );
            if (uint160(hook) & Hooks.ALL_HOOK_MASK == FLAGS) return (bytes32(i), hook);
        }
        revert("HookAddress: no salt");
    }
}
