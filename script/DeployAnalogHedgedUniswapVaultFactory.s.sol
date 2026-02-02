// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {AnalogHedgedUniswapVaultFactory} from "../src/AnalogHedgedUniswapVaultFactory.sol";
import {AnalogHedgedUniswapVault} from "../src/AnalogHedgedUniswapVault.sol";
import {AvantisHedgeAdapterFactory} from "../src/AvantisHedgeAdapterFactory.sol";

/**
 * @title DeployAnalogHedgedUniswapVaultFactory
 * @notice Script to deploy AnalogHedgedUniswapVaultFactory for WETH-USDC pool on Base
 *
 * Usage:
 *   forge script script/DeployAnalogHedgedUniswapVaultFactory.s.sol:DeployAnalogHedgedUniswapVaultFactory \
 *     --rpc-url $BASE_HTTP_RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast \
 *     --verify
 *
 * Or with environment variables:
 *   CONTROLLER_ADDRESS=0x... \
 *   STRATEGY_FACTORY_ADDRESS=0x... \
 *   forge script script/DeployAnalogHedgedUniswapVaultFactory.s.sol:DeployAnalogHedgedUniswapVaultFactory \
 *     --rpc-url $BASE_HTTP_RPC_URL \
 *     --broadcast \
 *     --verify
 */
contract DeployAnalogHedgedUniswapVaultFactory is Script {
  // Base mainnet addresses
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  address constant WETH = 0x4200000000000000000000000000000000000006;
  address constant POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224; // WETH/USDC 0.05%
  address constant ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70; // Chainlink ETH/USD on Base
  address constant STRATEGY_FACTORY = 0xf5628a987928B642620B9eA7A1648d280F3Cd035; // StrategyFactory from existing Uniswap strategy
  address constant QUOTER = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a; // Uniswap V3 Quoter V2
  address constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481; // SwapRouter02

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

    // Get StrategyFactory address (use default from existing Uniswap strategy if not provided)
    address strategyFactory = vm.envOr("STRATEGY_FACTORY_ADDRESS", STRATEGY_FACTORY);
    if (strategyFactory == address(0)) {
      revert("STRATEGY_FACTORY_ADDRESS environment variable is required");
    }

    // Get HedgeAdapterFactory address (required)
    address hedgeAdapterFactory = vm.envOr("HEDGE_ADAPTER_FACTORY_ADDRESS", address(0));
    if (hedgeAdapterFactory == address(0)) {
      revert("HEDGE_ADAPTER_FACTORY_ADDRESS environment variable is required");
    }

    console.log("========================================");
    console.log("Deploying AnalogHedgedUniswapVaultFactory");
    console.log("========================================");
    console.log("Deployer:", deployer);
    console.log("Controller:", controller);
    console.log("StrategyFactory:", strategyFactory);
    console.log("HedgeAdapterFactory:", hedgeAdapterFactory);
    console.log("");
    console.log("Configuration:");
    console.log("  USDC:", USDC);
    console.log("  WETH:", WETH);
    console.log("  Pool:", POOL);
    console.log("  ETH/USD Feed:", ETH_USD_FEED);
    console.log("  Quoter:", QUOTER);
    console.log("  Swap Router:", SWAP_ROUTER);
    console.log("");

    vm.startBroadcast(deployerPrivateKey);

    // First, deploy the vault implementation
    console.log("Deploying AnalogHedgedUniswapVault implementation...");
    AnalogHedgedUniswapVault vaultImpl = new AnalogHedgedUniswapVault(
      USDC,
      WETH,
      POOL,
      ETH_USD_FEED
    );
    console.log("Vault implementation deployed at:", address(vaultImpl));
    console.log("");

    // Deploy factory
    console.log("Deploying AnalogHedgedUniswapVaultFactory...");
    AnalogHedgedUniswapVaultFactory factory = new AnalogHedgedUniswapVaultFactory();
    console.log("Factory deployed at:", address(factory));
    console.log("");

    // Verify factory state
    console.log("Verifying factory state...");
    require(factory.usdc() == USDC, "USDC mismatch");
    require(factory.weth() == WETH, "WETH mismatch");
    require(factory.pool() == POOL, "Pool mismatch");
    require(factory.ethUsdFeed() == ETH_USD_FEED, "ETH/USD Feed mismatch");
    require(factory.strategyFactory() == strategyFactory, "StrategyFactory mismatch");
    require(factory.hedgeAdapterFactory() == hedgeAdapterFactory, "HedgeAdapterFactory mismatch");
    require(factory.quoter() == QUOTER, "Quoter mismatch");
    require(factory.swapRouter() == SWAP_ROUTER, "SwapRouter mismatch");
    require(factory.controller() == controller, "Controller mismatch");
    require(factory.latestImplementation() == address(vaultImpl), "Implementation mismatch");
    require(factory.owner() == deployer, "Owner mismatch");
    console.log("Factory verification passed");
    console.log("");

    vm.stopBroadcast();

    console.log("========================================");
    console.log("Deployment Complete");
    console.log("========================================");
    console.log("Factory Address:", address(factory));
    console.log("Vault Implementation Address:", address(vaultImpl));
    console.log("");
    console.log("Next steps:");
    console.log("1. Update strategy config with factory address:");
    console.log("   analogHedgedUniswapVaultFactoryAddress =", address(factory));
    console.log("2. Set controller if needed:");
    console.log("   factory.setController(0x...)");
    console.log("3. Register strategy in StrategyFactory if not already:");
    console.log("   strategyFactory.addStrategy(\"StrategyPassiveManagerUniswap\", 0x...)");
    console.log("4. After creating a vault, vault owner should call:");
    console.log("   factory.setAdapterOnVault(vaultAddress)");
    console.log("");
  }
}

