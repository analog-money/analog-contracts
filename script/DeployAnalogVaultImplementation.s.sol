// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {AnalogVault} from "../src/AnalogVault.sol";
import {AnalogVaultFactory} from "../src/AnalogVaultFactory.sol";

/**
 * @title DeployAnalogVaultImplementation
 * @notice Script to deploy new AnalogVault implementation and update factory
 *
 * This script deploys the new AnalogVault implementation with two-step withdrawal
 * functionality and updates the AnalogVaultFactory to use it.
 *
 * Usage:
 *   forge script script/DeployAnalogVaultImplementation.s.sol:DeployAnalogVaultImplementation \
 *     --rpc-url $RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast \
 *     --verify
 *
 * Or with environment variables:
 *   FACTORY_ADDRESS=0x... forge script script/DeployAnalogVaultImplementation.s.sol:DeployAnalogVaultImplementation \
 *     --rpc-url $BASE_HTTP_RPC_URL \
 *     --broadcast \
 *     --verify
 */
contract DeployAnalogVaultImplementation is Script {
  // Environment variables (optional)
  address factoryAddress = vm.envOr("FACTORY_ADDRESS", address(0));

  // Default test private key (only for simulation)
  uint256 constant DEFAULT_PRIVATE_KEY =
    0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

  function run() external {
    // Get deployer (use default for simulation if not set)
    uint256 deployerPrivateKey = vm.envOr("DEPLOYER_PRIVATE_KEY", DEFAULT_PRIVATE_KEY);
    address deployer = vm.addr(deployerPrivateKey);

    console.log("========================================");
    console.log("Deploying New AnalogVault Implementation");
    console.log("========================================");
    console.log("Deployer:", deployer);
    console.log("Factory Address:", factoryAddress);
    console.log("");

    vm.startBroadcast(deployerPrivateKey);

    // Deploy new AnalogVault implementation
    console.log("1. Deploying new AnalogVault implementation...");
    AnalogVault newImplementation = new AnalogVault();
    console.log("   New Implementation deployed at:", address(newImplementation));
    console.log("");

    // Update factory if address provided
    if (factoryAddress != address(0)) {
      console.log("2. Updating AnalogVaultFactory...");
      AnalogVaultFactory factory = AnalogVaultFactory(factoryAddress);

      // Get old implementation for logging
      address oldImplementation = factory.latestImplementation();
      console.log("   Old Implementation:", oldImplementation);
      console.log("   New Implementation:", address(newImplementation));

      // Update to new implementation
      factory.setLatestImplementation(address(newImplementation));
      console.log("   Factory updated successfully!");
      console.log("");

      // Check vaults needing upgrade (may revert if there are issues, so wrap in try-catch)
      try factory.getVaultCount() returns (uint256 vaultCount) {
        console.log("3. Vaults Status:");
        console.log("   Total vaults:", vaultCount);

        try factory.getVaultsNeedingUpgrade() returns (address[] memory vaultsNeedingUpgrade) {
          console.log("   Vaults needing upgrade:", vaultsNeedingUpgrade.length);

          if (vaultsNeedingUpgrade.length > 0) {
            console.log("");
            console.log("   Vaults that need to call upgradeToLatest():");
            for (uint256 i = 0; i < vaultsNeedingUpgrade.length && i < 10; i++) {
              console.log("     -", vaultsNeedingUpgrade[i]);
            }
            if (vaultsNeedingUpgrade.length > 10) {
              console.log("     ... and", vaultsNeedingUpgrade.length - 10, "more");
            }
          }
        } catch {
          console.log("   (Unable to check vaults needing upgrade)");
        }
      } catch {
        console.log("3. (Unable to check vault status)");
      }
    } else {
      console.log("2. Skipping factory update (FACTORY_ADDRESS not set)");
      console.log("   To update factory later, call:");
      console.log("   factory.setLatestImplementation(", address(newImplementation), ")");
    }

    vm.stopBroadcast();

    console.log("");
    console.log("========================================");
    console.log("Deployment Complete!");
    console.log("========================================");
    console.log("New AnalogVault Implementation:", address(newImplementation));
    console.log("");
    console.log("Next Steps:");
    console.log("1. Verify the contract on Basescan (if not auto-verified)");
    console.log("2. Submit ABI to Basescan (optional, for better UI):");
    console.log("   npx tsx script/submit-abi-to-basescan.ts \\");
    console.log("     --contract AnalogVault \\");
    console.log("     --address", address(newImplementation));
    console.log("   (Reads ETHERSCAN_API_KEY from .env file)");
    console.log("3. Existing vault owners can upgrade by calling:");
    console.log("   vault.upgradeToLatest()");
    console.log("4. New vaults will automatically use the new implementation");
    console.log("========================================");
  }
}
