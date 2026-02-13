// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {AnalogBalancerVaultFactory} from "../src/AnalogBalancerVaultFactory.sol";

/**
 * @title DeployAnalogBalancerVaultFactory
 * @notice Script to deploy AnalogBalancerVaultFactory for GHO-USDC pool on Base
 *
 * Usage:
 *   forge script script/DeployAnalogBalancerVaultFactory.s.sol:DeployAnalogBalancerVaultFactory \
 *     --rpc-url $BASE_HTTP_RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast \
 *     --verify
 *
 * Or with environment variables:
 *   CONTROLLER_ADDRESS=0x... forge script script/DeployAnalogBalancerVaultFactory.s.sol:DeployAnalogBalancerVaultFactory \
 *     --rpc-url $BASE_HTTP_RPC_URL \
 *     --broadcast \
 *     --verify
 */
contract DeployAnalogBalancerVaultFactory is Script {
  // Base mainnet addresses
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  address constant BALANCER_VAULT = 0xbA1333333333a1BA1108E8412f11850A5C319bA9;
  address constant BALANCER_ROUTER = 0x3f170631ed9821Ca51A59D996aB095162438DC10;
  address constant BALANCER_POOL = 0x7AB124EC4029316c2A42F713828ddf2a192B36db; // GHO-USDC pool
  address constant ONEINCH_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;
  address constant GHO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631; // GHO on Base

  // Default test private key (only for simulation)
  uint256 constant DEFAULT_PRIVATE_KEY =
    0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

  function run() external {
    // Get deployer (use default for simulation if not set)
    uint256 deployerPrivateKey = vm.envOr("DEPLOYER_PRIVATE_KEY", DEFAULT_PRIVATE_KEY);
    address deployer = vm.addr(deployerPrivateKey);

    // Get controller address (use deployer if not provided)
    address controller = vm.envOr("CONTROLLER_ADDRESS", deployer);
    if (controller == address(0)) {
      revert("CONTROLLER_ADDRESS environment variable is required or deployer must be valid");
    }

    console.log("========================================");
    console.log("Deploying AnalogBalancerVaultFactory");
    console.log("========================================");
    console.log("Deployer:", deployer);
    console.log("Controller:", controller);
    console.log("");
    console.log("Configuration:");
    console.log("  USDC:", USDC);
    console.log("  Balancer Vault:", BALANCER_VAULT);
    console.log("  Balancer Router:", BALANCER_ROUTER);
    console.log("  Pool:", BALANCER_POOL);
    console.log("  Token0 (GHO):", GHO);
    console.log("  Token1 (USDC):", USDC);
    console.log("  1inch Router:", ONEINCH_ROUTER);
    console.log("");

    vm.startBroadcast(deployerPrivateKey);

    // Deploy factory
    console.log("Deploying AnalogBalancerVaultFactory...");
    AnalogBalancerVaultFactory factory = new AnalogBalancerVaultFactory(
      msg.sender,
      USDC,
      BALANCER_VAULT,
      BALANCER_ROUTER,
      BALANCER_POOL,
      GHO,
      USDC,
      ONEINCH_ROUTER,
      controller
    );
    console.log("Factory deployed at:", address(factory));
    console.log("");

    // Verify factory state
    console.log("Verifying factory state...");
    require(factory.usdc() == USDC, "USDC mismatch");
    require(factory.balancerVault() == BALANCER_VAULT, "Balancer Vault mismatch");
    require(factory.balancerRouter() == BALANCER_ROUTER, "Balancer Router mismatch");
    require(factory.pool() == BALANCER_POOL, "Pool mismatch");
    require(factory.token0() == GHO, "Token0 mismatch");
    require(factory.token1() == USDC, "Token1 mismatch");
    require(factory.router() == ONEINCH_ROUTER, "Router mismatch");
    require(factory.controller() == controller, "Controller mismatch");
    require(factory.owner() == deployer, "Owner mismatch");
    console.log("Factory verification passed");
    console.log("");

    vm.stopBroadcast();

    console.log("========================================");
    console.log("Deployment Complete");
    console.log("========================================");
    console.log("Factory Address:", address(factory));
    console.log("");
    console.log("Next steps:");
    console.log("1. Update strategy config with factory address:");
    console.log("   analogBalancerVaultFactoryAddress =", address(factory));
    console.log("2. Set controller if needed:");
    console.log("   factory.setController(0x...)");
    console.log("");
  }
}


