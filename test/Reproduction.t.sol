// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {AnalogHedgedUniswapVault} from "../src/AnalogHedgedUniswapVault.sol";

contract ReproductionTest is Test {
    AnalogHedgedUniswapVault vault;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224;
    address constant ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org");
        vault = new AnalogHedgedUniswapVault(USDC, WETH, POOL, ETH_USD_FEED);
    }

    function testGetPendingStates() public {
        vault.getPendingStates();
    }
}
