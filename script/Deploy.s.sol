// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {Landlord} from "../src/Landlord.sol";
import {SeatDeskFactory} from "../src/SeatDesk.sol";
import {HookAddress} from "./HookAddress.sol";

/// @dev forge runs a script in its own EVM, which has no Arbitrum precompiles. This stands in for
/// ArbSys during that local run only; the broadcast transactions execute against the real one.
contract ArbSysSimulation {
    function arbBlockNumber() external view returns (uint256) {
        return block.number;
    }
}

/// @notice Deploys LANDLORD on Robinhood Chain, the SeatDesk factory next to it, and opens the
/// first pools. See DEPLOY.md.
///
/// env BURN_TOKEN       the LANDLORD token (exists at launch; a launch constant of the hook)
/// env BURN_POOL_FEE    fee of the plain LANDLORD/USDG v4 pool the crank buys on (>= 3000)
/// env BURN_POOL_TICK_SPACING
/// env OPEN_TOKENS      comma-separated stock tokens to open against USDG
/// env OPEN_REF_POOLS   comma-separated v4 pool ids whose current price each new pool opens at
contract Deploy is Script {
    using StateLibrary for IPoolManager;

    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    function run() external returns (Landlord hook, SeatDeskFactory desks) {
        require(block.chainid == 4663, "Robinhood Chain only");
        address burnToken = vm.envAddress("BURN_TOKEN");
        (address b0, address b1) = USDG < burnToken ? (USDG, burnToken) : (burnToken, USDG);
        PoolKey memory burnKey = PoolKey(
            Currency.wrap(b0),
            Currency.wrap(b1),
            uint24(vm.envUint("BURN_POOL_FEE")),
            int24(vm.envInt("BURN_POOL_TICK_SPACING")),
            IHooks(address(0))
        );

        bytes memory initCode = abi.encodePacked(
            type(Landlord).creationCode, abi.encode(PM, Currency.wrap(USDG), Currency.wrap(burnToken), burnKey)
        );
        (bytes32 salt, address predicted) = HookAddress.find(initCode);
        console2.log("hook address", predicted);

        address[] memory tokens = vm.envOr("OPEN_TOKENS", ",", new address[](0));
        bytes32[] memory refs = vm.envOr("OPEN_REF_POOLS", ",", new bytes32[](0));
        require(tokens.length == refs.length, "one reference pool per token");

        vm.etch(address(100), type(ArbSysSimulation).runtimeCode);
        vm.startBroadcast();
        (bool ok,) = HookAddress.CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        require(ok && predicted.code.length != 0, "deploy failed");
        hook = Landlord(predicted);
        desks = new SeatDeskFactory(PM, hook);
        console2.log("desk factory", address(desks));
        for (uint256 i; i < tokens.length; ++i) {
            (uint160 price,,,) = PM.getSlot0(PoolId.wrap(refs[i]));
            require(price != 0, "reference pool not initialized");
            (address c0, address c1) = USDG < tokens[i] ? (USDG, tokens[i]) : (tokens[i], USDG);
            PM.initialize(
                PoolKey(Currency.wrap(c0), Currency.wrap(c1), 0, hook.TICK_SPACING(), IHooks(predicted)), price
            );
            console2.log("opened pool for", tokens[i]);
        }
        vm.stopBroadcast();
    }
}
