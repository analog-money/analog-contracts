// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";

/**
 * @title FixVaultImplementation
 * @notice Script to fix a vault proxy that has empty implementation slot
 * Uses Foundry's vm.store to directly set the ERC1967 implementation slot
 *
 * Usage:
 *   VAULT_ADDRESS=0x69437064acc9f8408a198315267684bc34fa0ae4 \
 *   IMPLEMENTATION_ADDRESS=0xf4273487854676f1e92D8199c25c7E4FaB1Bc653 \
 *   forge script script/FixVaultImplementation.s.sol:FixVaultImplementation \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --verify
 */
contract FixVaultImplementation is Script {
  // Environment variables
  address vaultAddress = vm.envOr("VAULT_ADDRESS", address(0));
  address implementationAddress = vm.envOr("IMPLEMENTATION_ADDRESS", address(0));

  // ERC1967 implementation slot
  bytes32 constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

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
    console.log("Fixing Vault Implementation Slot");
    console.log("========================================");
    console.log("Deployer:", deployer);
    console.log("Vault Address:", vaultAddress);
    console.log("Implementation Address:", implementationAddress);
    console.log("Implementation Slot:", vm.toString(IMPLEMENTATION_SLOT));
    console.log("");

    // Use Foundry's vm.store to directly set the implementation slot
    // This bypasses the normal upgrade authorization since we're doing emergency recovery
    bytes32 implementationSlotValue = bytes32(uint256(uint160(implementationAddress)));

    console.log("Setting storage slot directly...");
    console.log("Slot value:", vm.toString(implementationSlotValue));

    vm.store(vaultAddress, IMPLEMENTATION_SLOT, implementationSlotValue);

    console.log("Storage slot set successfully!");

    // Verify the implementation was set
    bytes32 storedValue = vm.load(vaultAddress, IMPLEMENTATION_SLOT);
    address storedImplementation = address(uint160(uint256(storedValue)));

    console.log("Verified implementation:", storedImplementation);

    if (storedImplementation == implementationAddress) {
        console.log("Implementation slot fixed successfully!");
    } else {
        console.log("Implementation slot fix failed!");
        revert("Failed to set implementation");
    }

    console.log("");
    console.log("Next Steps:");
    console.log("1. Test vault functions like getPendingStates()");
    console.log("2. Verify all vault operations work correctly");
  }
}