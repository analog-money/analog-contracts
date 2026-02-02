// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {AnalogHedgedUniswapVaultFactory} from "../src/AnalogHedgedUniswapVaultFactory.sol";
import {AnalogHedgedUniswapVault} from "../src/AnalogHedgedUniswapVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployUpgradeableAnalogHedgedUniswapVaultFactory is Script {
    // Base mainnet addresses
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224; // WETH/USDC 0.05%
    address constant ETH_USD_FEED = 0x71041DDDaD3595f745215c98a9D63755012D9546;
    address constant QUOTER = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a;
    address constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    
    // Default strategy factory (check strictly)
    address constant STRATEGY_FACTORY = 0xf5628a987928B642620B9eA7A1648d280F3Cd035;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address controller = vm.envOr("CONTROLLER_ADDRESS", deployer);
        address hedgeAdapterFactory = vm.envAddress("HEDGE_ADAPTER_FACTORY_ADDRESS");
        address strategyFactory = vm.envOr("STRATEGY_FACTORY_ADDRESS", STRATEGY_FACTORY);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Vault Implementation
        AnalogHedgedUniswapVault vaultImpl = new AnalogHedgedUniswapVault(
            USDC,
            WETH,
            POOL,
            ETH_USD_FEED
        );
        console.log("Vault Implementation:", address(vaultImpl));

        // 2. Deploy Factory Implementation
        AnalogHedgedUniswapVaultFactory factoryImpl = new AnalogHedgedUniswapVaultFactory();
        console.log("Factory Implementation:", address(factoryImpl));

        // 3. Encode Initialization Data
        bytes memory initData = abi.encodeCall(
            AnalogHedgedUniswapVaultFactory.initialize,
            (
                USDC,
                WETH,
                POOL,
                ETH_USD_FEED,
                strategyFactory,
                hedgeAdapterFactory,
                QUOTER,
                SWAP_ROUTER,
                controller,
                address(vaultImpl)
            )
        );

        // 4. Deploy Proxy
        ERC1967Proxy proxy = new ERC1967Proxy(address(factoryImpl), initData);
        console.log("Factory Proxy:", address(proxy));

        vm.stopBroadcast();
    }
}
