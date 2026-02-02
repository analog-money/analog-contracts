// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {AnalogHedgedUniswapVault} from "../src/AnalogHedgedUniswapVault.sol";

/**
 * @title SetVaultImplementation
 * @notice Script to set implementation for a vault proxy that has empty implementation slot
 *
 * Usage:
 *   VAULT_ADDRESS=0x69437064acc9f8408a198315267684bc34fa0ae4 \
 *   IMPLEMENTATION_ADDRESS=0xf4273487854676f1e92D8199c25c7E4FaB1Bc653 \
 *   forge script script/SetVaultImplementation.s.sol:SetVaultImplementation \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --verify
 */
contract SetVaultImplementation is Script {
  // Environment variables
  address vaultAddress = vm.envOr("VAULT_ADDRESS", address(0));
  address implementationAddress = vm.envOr("IMPLEMENTATION_ADDRESS", address(0));

  // Default test private key (simulation)
  uint256 constant DEFAULT_PRIVATE_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

  function run() external {
    uint256 deployerPrivateKey = vm.envOr("DEPLOYER_PRIVATE_KEY", DEFAULT_PRIVATE_KEY);
    address deployer = vm.addr(deployerPrivateKey);

    if (vaultAddress == address(0)) {
        revert("VAULT_ADDRESS environment variable is required");
    }
    if (implementationAddress == address(0)) {
        revert("IMPLEMENTATION_ADDRESS environment variable is required");
    }

    console.log("========================================");
    console.log("Setting Vault Implementation");
    console.log("========================================");
    console.log("Deployer:", deployer);
    console.log("Vault Address:", vaultAddress);
    console.log("Implementation Address:", implementationAddress);
    console.log("");

    vm.startBroadcast(deployerPrivateKey);

    AnalogHedgedUniswapVault vault = AnalogHedgedUniswapVault(payable(vaultAddress));

    // Check current implementation
    address currentImpl = vault.getImplementation();
    console.log("Current implementation:", currentImpl);

    if (currentImpl != address(0)) {
        console.log("Vault already has implementation set!");
        return;
    }

    // Check that we're the controller (should be able to call upgradeToAndCall)
    // The _authorizeUpgrade function should allow this since we're the controller
    console.log("Setting implementation...");

    vault.upgradeToAndCall(implementationAddress, "");

    // Verify the implementation was set
    address newImpl = vault.getImplementation();
    console.log("New implementation:", newImpl);

    if (newImpl == implementationAddress) {
        console.log("Implementation set successfully!");
    } else {
        console.log("Implementation setting failed!");
    }

    vm.stopBroadcast();

    console.log("");
    console.log("Next Steps:");
    console.log("1. Verify the vault can now call getPendingStates()");
    console.log("2. Test other vault functions");
  }
}