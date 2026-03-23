// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AnalogVault} from "../src/AnalogVault.sol";
import {AnalogVaultFactory} from "../src/AnalogVaultFactory.sol";
import {StrategyFactory} from "../src/StrategyFactory.sol";
import {TestStrategyPassiveManagerUniswap} from "../src/TestStrategyPassiveManagerUniswap.sol";
import {StratFeeManagerInitializable as BStratFM} from "beefy-zk/strategies/StratFeeManagerInitializable.sol";

/**
 * @title CheckStrategyCalm
 * @notice Tests calm/not-calm behavior on a real strategy with LP position
 */
contract CheckStrategyCalm is Test {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224;
    address constant QUOTER = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a;
    address constant UNIROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;

    address constant CONTROLLER = address(0xC0C0);
    address constant USER = address(0xABCD);
    address constant STRATEGIST = address(0x5555);

    AnalogVault vault;
    TestStrategyPassiveManagerUniswap strategy;

    function setUp() public {
        string memory rpcUrl = "https://mainnet.base.org";
        try vm.envString("BASE_HTTP_RPC_URL") returns (string memory url) {
            rpcUrl = url;
        } catch {}
        vm.createSelectFork(rpcUrl);

        vm.deal(USER, 10 ether);

        StrategyFactory strategyFactory = new StrategyFactory(WETH, address(this), address(this), address(0));
        TestStrategyPassiveManagerUniswap stratImpl = new TestStrategyPassiveManagerUniswap();
        strategyFactory.addStrategy("TestStrategyPassiveManagerUniswap", address(stratImpl));

        AnalogVault vaultImpl = new AnalogVault(USDC);
        AnalogVaultFactory factoryImpl = new AnalogVaultFactory();
        bytes memory initData = abi.encodeWithSelector(
            AnalogVaultFactory.initialize.selector,
            address(this), USDC, address(strategyFactory), CONTROLLER, address(vaultImpl)
        );
        AnalogVaultFactory factory = AnalogVaultFactory(address(new ERC1967Proxy(address(factoryImpl), initData)));

        (address vaultAddr, address stratAddr) = factory.createVault(USER, "TestStrategyPassiveManagerUniswap");
        AnalogVault(payable(vaultAddr)).transferOwnership(USER);

        vault = AnalogVault(payable(vaultAddr));
        strategy = TestStrategyPassiveManagerUniswap(stratAddr);

        BStratFM.CommonAddresses memory common = BStratFM.CommonAddresses({
            vault: vaultAddr, unirouter: UNIROUTER, strategist: STRATEGIST, factory: address(strategyFactory)
        });
        strategy.initialize(POOL, QUOTER, int24(25), "", abi.encodePacked(USDC, uint24(500), WETH), common);
        strategy.setDeviation(int56(39));

        // Fund vault with LP position
        uint256 depositAmount = 1000e6;
        deal(USDC, USER, depositAmount, true);
        vm.startPrank(USER);
        IERC20(USDC).approve(vaultAddr, depositAmount);
        vault.deposit(depositAmount);
        vm.stopPrank();
        vm.prank(CONTROLLER);
        vault.depositExecute();
        vm.roll(block.number + 10);
    }

    /// @notice Verify isCalm returns true with deviation=39 on a normal pool
    function test_check_calm() public view {
        bool calm = strategy.isCalm();
        assertTrue(calm, "Pool should be calm with deviation 39");
    }

    /// @notice With deviation=0, pool should not be calm (tick must exactly equal TWAP)
    function test_update_during_non_calm_reverts() public {
        // Set deviation to 0 — pool is effectively never calm
        vm.prank(strategy.owner());
        strategy.setDeviation(int56(0));

        assertFalse(strategy.isCalm(), "Pool should not be calm with deviation 0");

        // setPositionWidth should revert with NotCalm
        vm.prank(strategy.owner());
        vm.expectRevert();
        strategy.setPositionWidth(int24(50));
    }
}
