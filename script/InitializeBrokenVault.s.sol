// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {AnalogHedgedUniswapVault} from "../src/AnalogHedgedUniswapVault.sol";

/**
 * @title InitializeBrokenVault
 * @notice Script to manually initialize a vault that failed to initialize during deployment
 *
 * Usage:
 *   VAULT_ADDRESS=0x69437064acc9f8408a198315267684bc34fa0ae4 \
 *   OWNER_ADDRESS=0x5811f3bdd678d68b2fa1e107750017b68d2abd92 \
 *   forge script script/InitializeBrokenVault.s.sol:InitializeBrokenVault \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --verify
 */
contract InitializeBrokenVault is Script {
  // Environment variables
  address vaultAddress = vm.envOr("VAULT_ADDRESS", address(0));
  address ownerAddress = vm.envOr("OWNER_ADDRESS", address(0));

  // Default test private key (simulation)
  uint256 constant DEFAULT_PRIVATE_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

  function run() external {
    uint256 deployerPrivateKey = vm.envOr("DEPLOYER_PRIVATE_KEY", DEFAULT_PRIVATE_KEY);
    address deployer = vm.addr(deployerPrivateKey);

    if (vaultAddress == address(0)) {
        revert("VAULT_ADDRESS environment variable is required");
    }
    if (ownerAddress == address(0)) {
        revert("OWNER_ADDRESS environment variable is required");
    }

    console.log("========================================");
    console.log("Initializing Broken Vault");
    console.log("========================================");
    console.log("Deployer:", deployer);
    console.log("Vault Address:", vaultAddress);
    console.log("Owner Address:", ownerAddress);
    console.log("");

    vm.startBroadcast(deployerPrivateKey);

    AnalogHedgedUniswapVault vault = AnalogHedgedUniswapVault(payable(vaultAddress));

    // Check current state
    address currentOwner = vault.owner();
    console.log("Current owner:", currentOwner);

    if (currentOwner != address(0)) {
        console.log("Vault is already initialized!");
        return;
    }

    // Initialize the vault with correct parameters
    // These match what the factory should have initialized with
    address controller = 0x25e21aBcd8FF244914eb03dA2EBA7ea62EfF6821;
    address usdc = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address weth = 0x4200000000000000000000000000000000000006;
    address strategy = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    console.log("Initializing vault with:");
    console.log("  Owner:", ownerAddress);
    console.log("  Controller:", controller);
    console.log("  USDC:", usdc);
    console.log("  WETH:", weth);
    console.log("  Strategy:", strategy);

    vault.initialize(ownerAddress, controller, usdc, weth, strategy);

    // Verify initialization
    address newOwner = vault.owner();
    console.log("New owner after initialization:", newOwner);

    if (newOwner == ownerAddress) {
        console.log("Vault initialized successfully!");
    } else {
        console.log("Vault initialization failed!");
    }

    vm.stopBroadcast();

    console.log("");
    console.log("Next Steps:");
    console.log("1. Verify the vault owner can now call getPendingStates()");
    console.log("2. If needed, the vault owner should call approveSwaps() to approve token transfers");
  }
}