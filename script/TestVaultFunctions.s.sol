// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {AnalogHedgedUniswapVault} from "../src/AnalogHedgedUniswapVault.sol";

/**
 * @title TestVaultFunctions
 * @notice Script to test vault functions including getPendingStates
 *
 * Usage:
 *   VAULT_ADDRESS=0x69437064acc9f8408a198315267684bc34fa0ae4 \
 *   forge script script/TestVaultFunctions.s.sol:TestVaultFunctions \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --verify
 */
contract TestVaultFunctions is Script {
  // Environment variables
  address vaultAddress = vm.envOr("VAULT_ADDRESS", address(0));

  // Default test private key (simulation)
  uint256 constant DEFAULT_PRIVATE_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

  function run() external view {
    if (vaultAddress == address(0)) {
        revert("VAULT_ADDRESS environment variable is required");
    }

    console.log("========================================");
    console.log("Testing Vault Functions");
    console.log("========================================");
    console.log("Vault Address:", vaultAddress);
    console.log("");

    AnalogHedgedUniswapVault vault = AnalogHedgedUniswapVault(payable(vaultAddress));

    // Test owner
    try vault.owner() returns (address owner) {
      console.log("PASS owner():", owner);
    } catch (bytes memory reason) {
      console.log("FAIL owner() failed:", string(reason));
    }

    // Test controller
    try vault.controller() returns (address controller) {
      console.log("PASS controller():", controller);
    } catch (bytes memory reason) {
      console.log("FAIL controller() failed:", string(reason));
    }

    // Test getImplementation
    try vault.getImplementation() returns (address impl) {
      console.log("PASS getImplementation():", impl);
    } catch (bytes memory reason) {
      console.log("FAIL getImplementation() failed:", string(reason));
    }

    // Test getPendingStates
    try vault.getPendingStates() returns (
      uint256 depositAmount,
      bool depositPending,
      uint256 withdrawalAmount,
      bool withdrawalPending,
      uint256 swapToken0,
      uint256 swapToken1,
      address swapRecipient,
      bool swapPending,
      uint256 deployAmount0,
      uint256 deployAmount1,
      bool deployPending,
      uint8 configType,
      int256 configValue,
      bool configPending
    ) {
      console.log("PASS getPendingStates() succeeded!");
      console.log("  depositAmount:", depositAmount);
      console.log("  depositPending:", depositPending);
      console.log("  withdrawalAmount:", withdrawalAmount);
      console.log("  withdrawalPending:", withdrawalPending);
      console.log("  configType:", configType);
      console.log("  configValue:", configValue);
      console.log("  configPending:", configPending);
    } catch (bytes memory reason) {
      console.log("FAIL getPendingStates() failed:", string(reason));
    }
  }
}