// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {AnalogHedgedUniswapVaultFactory} from "../src/AnalogHedgedUniswapVaultFactory.sol";

contract SetFactoryImplementation is Script {
  function run() external {
    uint256 deployerPrivateKey = vm.envOr(
      "DEPLOYER_PRIVATE_KEY",
      uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
    );

    address factoryAddress = vm.envAddress("FACTORY_ADDRESS");
    address newImpl = vm.envAddress("NEW_IMPLEMENTATION");

    console.log("Updating Factory Implementation");
    console.log("Factory:", factoryAddress);
    console.log("New Implementation:", newImpl);

    vm.startBroadcast(deployerPrivateKey);

    AnalogHedgedUniswapVaultFactory factory = AnalogHedgedUniswapVaultFactory(factoryAddress);

    address oldImpl = factory.latestImplementation();
    console.log("Old Implementation:", oldImpl);

    factory.setLatestImplementation(newImpl);
    console.log("Factory updated successfully!");

    vm.stopBroadcast();

    console.log("");
    console.log("Verification:");
    console.log("Latest Implementation:", factory.latestImplementation());
  }
}
