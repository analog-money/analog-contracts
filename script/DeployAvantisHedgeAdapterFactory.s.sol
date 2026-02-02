// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {AvantisHedgeAdapterFactory} from "../src/AvantisHedgeAdapterFactory.sol";
import {AvantisHedgeAdapter} from "../src/hedge/AvantisHedgeAdapter.sol";

/**
 * @title DeployAvantisHedgeAdapterFactory
 * @notice Script to deploy AvantisHedgeAdapterFactory on Base
 *
 * Usage:
 *   forge script script/DeployAvantisHedgeAdapterFactory.s.sol:DeployAvantisHedgeAdapterFactory \
 *     --rpc-url $BASE_HTTP_RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast \
 *     --verify
 *
 * Or with environment variables:
 *   forge script script/DeployAvantisHedgeAdapterFactory.s.sol:DeployAvantisHedgeAdapterFactory \
 *     --rpc-url $BASE_HTTP_RPC_URL \
 *     --broadcast \
 *     --verify
 */
contract DeployAvantisHedgeAdapterFactory is Script {
  // Base mainnet addresses
  address constant ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70; // Chainlink ETH/USD on Base

  // Default test private key (only for simulation)
  uint256 constant DEFAULT_PRIVATE_KEY =
    0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

  function run() external {
    // Get deployer (use default for simulation if not set)
    uint256 deployerPrivateKey = vm.envOr("DEPLOYER_PRIVATE_KEY", DEFAULT_PRIVATE_KEY);
    address deployer = vm.addr(deployerPrivateKey);

    console.log("========================================");
    console.log("Deploying AvantisHedgeAdapterFactory");
    console.log("========================================");
    console.log("Deployer:", deployer);
    console.log("");
    console.log("Configuration:");
    console.log("  ETH/USD Feed:", ETH_USD_FEED);
    console.log("");

    vm.startBroadcast(deployerPrivateKey);

    // Deploy factory
    console.log("Deploying AvantisHedgeAdapterFactory...");
    AvantisHedgeAdapterFactory factory = new AvantisHedgeAdapterFactory();
    console.log("Factory deployed at:", address(factory));
    console.log("");

    // Optionally create and set default adapter
    bool createDefault = vm.envOr("CREATE_DEFAULT_ADAPTER", false);
    if (createDefault) {
      console.log("Creating default shared adapter...");
      address defaultAdapter = factory.createDefaultAdapter(address(0)); // Use default feed
      console.log("Default adapter deployed at:", defaultAdapter);
      console.log("");
    }

    // Verify factory state
    console.log("Verifying factory state...");
    require(factory.defaultEthUsdFeed() == ETH_USD_FEED, "ETH/USD Feed mismatch");
    require(factory.owner() == deployer, "Owner mismatch");
    console.log("Factory verification passed");
    console.log("");

    vm.stopBroadcast();

    console.log("========================================");
    console.log("Deployment Complete");
    console.log("========================================");
    console.log("Factory Address:", address(factory));
    if (createDefault) {
      console.log("Default Adapter Address:", factory.defaultAdapter());
    }
    console.log("");
    console.log("Next steps:");
    console.log("1. Update strategy config with factory address:");
    console.log("   avantisHedgeAdapterFactoryAddress =", address(factory));
    if (!createDefault) {
      console.log("2. Create default adapter:");
      console.log("   factory.createDefaultAdapter(address(0))");
    }
    console.log("3. Vaults can use the default adapter or create per-vault adapters");
    console.log("");
  }
}

