// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {AvantisHedgeAdapterFactory} from "../src/AvantisHedgeAdapterFactory.sol";
import {AvantisHedgeAdapter} from "../src/hedge/AvantisHedgeAdapter.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title DeployUpgradeableAvantisHedgeAdapterFactory
 * @notice Script to deploy AvantisHedgeAdapterFactory as UUPS upgradeable proxy
 */
contract DeployUpgradeableAvantisHedgeAdapterFactory is Script {
    // Base mainnet addresses
    address constant ETH_USD_FEED = 0x71041DDDaD3595f745215c98a9D63755012D9546;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address ethUsdFeed = vm.envOr("ETH_USD_FEED_ADDRESS", ETH_USD_FEED);

        console.log("========================================");
        console.log("Deploying Upgradeable AvantisHedgeAdapterFactory");
        console.log("========================================");
        console.log("Deployer:", deployer);
        console.log("ETH/USD Feed:", ethUsdFeed);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Adapter Implementation (for clones)
        AvantisHedgeAdapter adapterImpl = new AvantisHedgeAdapter();
        console.log("Adapter Implementation:", address(adapterImpl));

        // 2. Deploy Factory Implementation
        AvantisHedgeAdapterFactory implementation = new AvantisHedgeAdapterFactory();
        console.log("Factory Implementation:", address(implementation));

        // 3. Encode Initialization Data
        bytes memory initData = abi.encodeCall(
            AvantisHedgeAdapterFactory.initialize,
            (ethUsdFeed, address(adapterImpl))
        );

        // 4. Deploy UUPS Proxy
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        console.log("Factory Proxy:", address(proxy));

        vm.stopBroadcast();

        // 4. Verify
        AvantisHedgeAdapterFactory factory = AvantisHedgeAdapterFactory(address(proxy));
        require(factory.owner() == deployer, "Owner mismatch");
        require(factory.defaultEthUsdFeed() == ethUsdFeed, "ETH/USD Feed mismatch");

        console.log("========================================");
        console.log("Deployment Complete");
        console.log("========================================");
        console.log("Implementation:", address(implementation));
        console.log("Proxy (Use this address):", address(proxy));
        console.log("");
    }
}
