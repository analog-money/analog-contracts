// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {AnalogHedgedUniswapVault} from "../src/AnalogHedgedUniswapVault.sol";

contract DeployImplementationOnly is Script {
  function run() external {
    uint256 deployerPrivateKey = vm.envOr(
      "DEPLOYER_PRIVATE_KEY",
      uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
    );

    address usdc = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address weth = 0x4200000000000000000000000000000000000006;
    address pool = 0xd0b53D9277642d899DF5C87A3966A349A798F224;
    address feed = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

    console.log("Deploying AnalogHedgedUniswapVault implementation...");
    console.log("USDC:", usdc);
    console.log("WETH:", weth);
    console.log("Pool:", pool);
    console.log("Feed:", feed);

    vm.startBroadcast(deployerPrivateKey);

    AnalogHedgedUniswapVault impl = new AnalogHedgedUniswapVault(
      usdc,
      weth,
      pool,
      feed
    );

    vm.stopBroadcast();

    console.log("Implementation deployed at:", address(impl));
  }
}
