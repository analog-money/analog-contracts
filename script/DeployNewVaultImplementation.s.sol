// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {AnalogHedgedUniswapVault} from "../src/AnalogHedgedUniswapVault.sol";

/**
 * @title DeployNewVaultImplementation
 * @notice Deploy a new vault implementation with getPendingStates() function
 *
 * Usage:
 *   forge script script/DeployNewVaultImplementation.s.sol:DeployNewVaultImplementation \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --verify
 */
contract DeployNewVaultImplementation is Script {
  // Same constructor parameters as the original vault
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  address constant WETH = 0x4200000000000000000000000000000000000006;
  address constant POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224;
  address constant ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

  function run() external {
    uint256 deployerPrivateKey = 0xfa636d67f328b91220f3de9f9be2107311dc0601bd2b052951f6119a9a7b0987;
    address deployer = vm.addr(deployerPrivateKey);

    console.log("========================================");
    console.log("Deploying New Vault Implementation");
    console.log("========================================");
    console.log("Deployer:", deployer);
    console.log("");

    vm.startBroadcast(deployerPrivateKey);

    // Deploy new implementation with getPendingStates() function
    AnalogHedgedUniswapVault implementation = new AnalogHedgedUniswapVault(
      USDC,
      WETH,
      POOL,
      ETH_USD_FEED
    );

    console.log("New implementation deployed at:", address(implementation));

    vm.stopBroadcast();

    console.log("");
    console.log("Next Steps:");
    console.log("1. Use the implementation address above to set the vault's implementation slot");
    console.log("2. Call upgradeToAndCall on the vault (if owner allows) or set storage slot directly");
  }
}