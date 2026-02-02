// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {AnalogVaultFactory} from "../src/AnalogVaultFactory.sol";
import {AnalogVault} from "../src/AnalogVault.sol";

/**
 * @title DeployAnalogVaultFactory
 * @notice Script to deploy AnalogVaultFactory for Base
 *
 * Usage:
 *   forge script script/DeployAnalogVaultFactory.s.sol:DeployAnalogVaultFactory \
 *     --rpc-url $BASE_HTTP_RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast \
 *     --verify
 *
 * Or with environment variables:
 *   CONTROLLER_ADDRESS=0x... \
 *   STRATEGY_FACTORY_ADDRESS=0x... \
 *   forge script script/DeployAnalogVaultFactory.s.sol:DeployAnalogVaultFactory \
 *     --rpc-url $BASE_HTTP_RPC_URL \
 *     --broadcast \
 *     --verify
 */
contract DeployAnalogVaultFactory is Script {
    // Base mainnet addresses
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant STRATEGY_FACTORY = 0xf5628a987928B642620B9eA7A1648d280F3Cd035; // StrategyFactory from existing deployment

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

        // Get StrategyFactory address (use default from existing deployment if not provided)
        address strategyFactory = vm.envOr("STRATEGY_FACTORY_ADDRESS", STRATEGY_FACTORY);
        if (strategyFactory == address(0)) {
            revert("STRATEGY_FACTORY_ADDRESS environment variable is required");
        }

        console.log("========================================");
        console.log("Deploying AnalogVaultFactory");
        console.log("========================================");
        console.log("Deployer:", deployer);
        console.log("Controller:", controller);
        console.log("StrategyFactory:", strategyFactory);
        console.log("");
        console.log("Configuration:");
        console.log("  USDC:", USDC);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // First, deploy the vault implementation
        console.log("Deploying AnalogVault implementation...");
        AnalogVault vaultImpl = new AnalogVault();
        console.log("Vault implementation deployed at:", address(vaultImpl));
        console.log("");

        // Deploy factory
        console.log("Deploying AnalogVaultFactory...");
        AnalogVaultFactory factory = new AnalogVaultFactory();
        console.log("Factory deployed at:", address(factory));
        console.log("");

        // Verify factory state
        console.log("Verifying factory state...");
        require(factory.usdc() == USDC, "USDC mismatch");
        require(factory.strategyFactory() == strategyFactory, "StrategyFactory mismatch");
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
        console.log("   analogVaultFactoryAddress =", address(factory));
        console.log("2. Set controller if needed:");
        console.log("   factory.setController(0x...)");
        console.log("3. Register strategy in StrategyFactory if not already:");
        console.log("   strategyFactory.addStrategy(\"StrategyPassiveManagerUniswap\", 0x...)");
        console.log("4. Vault ownership will be transferred via factory helper after initialization");
        console.log("");
    }
}
