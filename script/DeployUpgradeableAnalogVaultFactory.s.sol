// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {AnalogVaultFactory} from "../src/AnalogVaultFactory.sol";
import {AnalogVault} from "../src/AnalogVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployUpgradeableAnalogVaultFactory is Script {
    // Base mainnet addresses
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant STRATEGY_FACTORY = 0xf5628a987928B642620B9eA7A1648d280F3Cd035;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address controller = vm.envOr("CONTROLLER_ADDRESS", deployer);
        address strategyFactory = vm.envOr("STRATEGY_FACTORY_ADDRESS", STRATEGY_FACTORY);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Vault Implementation
        AnalogVault vaultImpl = new AnalogVault();
        console.log("Vault Implementation:", address(vaultImpl));

        // 2. Deploy Factory Implementation
        AnalogVaultFactory factoryImpl = new AnalogVaultFactory();
        console.log("Factory Implementation:", address(factoryImpl));

        // 3. Encode Initialization Data
        bytes memory initData = abi.encodeCall(
            AnalogVaultFactory.initialize,
            (
                USDC,
                strategyFactory,
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
