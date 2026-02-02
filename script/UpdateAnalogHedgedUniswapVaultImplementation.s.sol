// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {AnalogHedgedUniswapVault} from "../src/AnalogHedgedUniswapVault.sol";
import {AnalogHedgedUniswapVaultFactory} from "../src/AnalogHedgedUniswapVaultFactory.sol";

/**
 * @title UpdateAnalogHedgedUniswapVaultImplementation
 * @notice Script to deploy new AnalogHedgedUniswapVault implementation and update factory
 *
 * Usage:
 *   FACTORY_ADDRESS=0x... forge script script/UpdateAnalogHedgedUniswapVaultImplementation.s.sol:UpdateAnalogHedgedUniswapVaultImplementation \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --verify
 */
contract UpdateAnalogHedgedUniswapVaultImplementation is Script {
  // Environment variables
  address factoryAddress = vm.envOr("FACTORY_ADDRESS", address(0));

  // Default test private key (simulation)
  uint256 constant DEFAULT_PRIVATE_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

  function run() external {
    uint256 deployerPrivateKey = vm.envOr("DEPLOYER_PRIVATE_KEY", DEFAULT_PRIVATE_KEY);
    address deployer = vm.addr(deployerPrivateKey);

    if (factoryAddress == address(0)) {
        revert("FACTORY_ADDRESS environment variable is required");
    }

    console.log("========================================");
    console.log("Updating AnalogHedgedUniswapVault Implementation");
    console.log("========================================");
    console.log("Deployer:", deployer);
    console.log("Factory:", factoryAddress);
    console.log("");

    vm.startBroadcast(deployerPrivateKey);

    AnalogHedgedUniswapVaultFactory factory = AnalogHedgedUniswapVaultFactory(factoryAddress);

    // Read config from factory
    address usdc = factory.usdc();
    address weth = factory.weth();
    address pool = factory.pool();
    address feed = factory.ethUsdFeed();

    console.log("Factory Config:");
    console.log("  USDC:", usdc);
    console.log("  WETH:", weth);
    console.log("  Pool:", pool);
    console.log("  Feed:", feed);
    console.log("");

    // 1. Deploy new Implementation
    console.log("1. Deploying new AnalogHedgedUniswapVault implementation...");
    AnalogHedgedUniswapVault newImpl = new AnalogHedgedUniswapVault(usdc, weth, pool, feed);
    console.log("   Address:", address(newImpl));

    // 2. Update Factory
    console.log("2. Updating Factory latestImplementation...");
    address oldImpl = factory.latestImplementation();
    console.log("   Old Impl:", oldImpl);
    
    factory.setLatestImplementation(address(newImpl));
    console.log("   Factory updated successfully!");

    vm.stopBroadcast();
    
    console.log("");
    console.log("Next Steps:");
    console.log("1. Verify contract on Etherscan/Basescan");
    console.log("2. Existing vault owners should call vault.upgradeToLatest()");
  }
}
