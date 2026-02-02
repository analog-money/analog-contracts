// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {AnalogHedgedUniswapVaultFactory} from "../src/AnalogHedgedUniswapVaultFactory.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title UpgradeAnalogHedgedUniswapVaultFactory
 * @notice Script to upgrade AnalogHedgedUniswapVaultFactory and set new hedge adapter factory
 */
contract UpgradeAnalogHedgedUniswapVaultFactory is Script {
    // Current Proxy Address (deployed in previous step)
    address constant PROXY_ADDRESS = 0x0bF76Fa0700F43C516F2aa1D3B24D715bcf6321B;
    
    // New Avantis Factory Address
    address constant NEW_ADAPTER_FACTORY = 0x4184B5b155c308f6f8706C23B16C4101C9fe00e4;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("========================================");
        console.log("Upgrading AnalogHedgedUniswapVaultFactory");
        console.log("========================================");
        console.log("Proxy:", PROXY_ADDRESS);
        console.log("New Adapter Factory:", NEW_ADAPTER_FACTORY);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy New Implementation
        AnalogHedgedUniswapVaultFactory newImplementation = new AnalogHedgedUniswapVaultFactory();
        console.log("New Implementation:", address(newImplementation));

        // 2. Upgrade Proxy and Set New Adapter Factory Atomically
        AnalogHedgedUniswapVaultFactory factory = AnalogHedgedUniswapVaultFactory(PROXY_ADDRESS);
        
        bytes memory data = abi.encodeCall(
            AnalogHedgedUniswapVaultFactory.setHedgeAdapterFactory,
            (NEW_ADAPTER_FACTORY)
        );
        
        factory.upgradeToAndCall(address(newImplementation), data);
        console.log("Upgraded proxy and set new adapter factory");

        vm.stopBroadcast();

        // 4. Verify
        require(factory.hedgeAdapterFactory() == NEW_ADAPTER_FACTORY, "Adapter Factory mismatch");

        console.log("========================================");
        console.log("Upgrade Complete");
        console.log("========================================");
    }
}
