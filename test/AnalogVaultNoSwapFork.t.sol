// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {AnalogVault} from "../src/AnalogVault.sol";
import {AnalogVaultFactory} from "../src/AnalogVaultFactory.sol";
import {StrategyFactory} from "../src/StrategyFactory.sol";
import {
    TestStrategyPassiveManagerUniswap
} from "../src/TestStrategyPassiveManagerUniswap.sol";
import {IStrategyConcLiq} from "beefy-zk/interfaces/beefy/IStrategyConcLiq.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    StratFeeManagerInitializable
} from "beefy-zk/strategies/StratFeeManagerInitializable.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title AnalogVaultNoSwapForkTest
 * @notice Fork test to verify that strategy can handle single-sided USDC deposits
 * via the new 2-step depositExecute flow (no external swap needed).
 *
 * To run this test:
 *   forge test --match-contract AnalogVaultNoSwapForkTest -vvv --fork-url $BASE_HTTP_RPC_URL
 */
contract AnalogVaultNoSwapForkTest is Test {
    // Base Mainnet addresses
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;

    // Uniswap V3 addresses on Base
    address constant POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224; // USDC-WETH pool
    address constant QUOTER = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a;
    address constant UNIROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;

    // Test addresses
    address constant CONTROLLER =
        address(0x1111111111111111111111111111111111111111);
    address constant USER1 =
        address(0x2222222222222222222222222222222222222222);
    address constant STRATEGIST =
        address(0x5555555555555555555555555555555555555555);

    // Strategy name for testing
    string constant STRATEGY_NAME = "TestStrategyPassiveManagerUniswap";

    AnalogVaultFactory factory;
    StrategyFactory strategyFactory;
    TestStrategyPassiveManagerUniswap strategyImplementation;

    function setUp() public {
        // Fork Base mainnet
        string memory rpcUrl = "https://mainnet.base.org";
        try vm.envString("BASE_HTTP_RPC_URL") returns (string memory url) {
            rpcUrl = url;
        } catch {}
        vm.createSelectFork(rpcUrl);

        // Label addresses
        vm.label(USDC, "USDC");
        vm.label(WETH, "WETH");
        vm.label(POOL, "UNIV3_POOL");
        vm.label(QUOTER, "UNIV3_QUOTER");
        vm.label(UNIROUTER, "UNIROUTER");
        vm.label(CONTROLLER, "CONTROLLER");
        vm.label(USER1, "USER1");
        vm.label(STRATEGIST, "STRATEGIST");

        // Deploy StrategyFactory
        strategyFactory = new StrategyFactory(
            WETH,
            address(this),
            address(this),
            address(0)
        );
        vm.label(address(strategyFactory), "STRATEGY_FACTORY");

        // Deploy strategy implementation and register it
        strategyImplementation = new TestStrategyPassiveManagerUniswap();
        vm.label(address(strategyImplementation), "STRATEGY_IMPL");

        strategyFactory.addStrategy(
            STRATEGY_NAME,
            address(strategyImplementation)
        );

        // Deploy AnalogVault implementation
        AnalogVault vaultImplementation = new AnalogVault(USDC);
        vm.label(address(vaultImplementation), "ANALOG_VAULT_IMPL");

        // Deploy AnalogVaultFactory behind proxy
        AnalogVaultFactory factoryImpl = new AnalogVaultFactory();
        bytes memory factoryInitData = abi.encodeWithSelector(
            AnalogVaultFactory.initialize.selector,
            address(this),
            USDC,
            address(strategyFactory),
            CONTROLLER,
            address(vaultImplementation)
        );
        factory = AnalogVaultFactory(address(new ERC1967Proxy(address(factoryImpl), factoryInitData)));
        vm.label(address(factory), "ANALOG_VAULT_FACTORY");

        // Give users some ETH for gas
        vm.deal(USER1, 10 ether);
        vm.deal(CONTROLLER, 10 ether);
    }

    /**
     * @notice Helper function to initialize a strategy with proper parameters
     */
    function initializeStrategy(address strategy, address vault) internal {
        StratFeeManagerInitializable.CommonAddresses
            memory commonAddresses = StratFeeManagerInitializable
                .CommonAddresses({
                    vault: vault,
                    unirouter: UNIROUTER,
                    strategist: STRATEGIST,
                    factory: address(strategyFactory)
                });

        int24 positionWidth = 10;
        bytes memory lpToken0ToNativePath = "";
        bytes memory lpToken1ToNativePath = abi.encodePacked(
            USDC,
            uint24(500),
            WETH
        );

        TestStrategyPassiveManagerUniswap(strategy).initialize(
            POOL,
            QUOTER,
            positionWidth,
            lpToken0ToNativePath,
            lpToken1ToNativePath,
            commonAddresses
        );

        // Set maxTickDeviation so isCalm() returns true on fork
        TestStrategyPassiveManagerUniswap(strategy).setDeviation(int56(39));
    }

    /**
     * @notice Helper to deploy vault and strategy via factory
     */
    function deployVaultAndStrategy() internal returns (address vaultAddr, address strategyAddr) {
        (vaultAddr, strategyAddr) = factory.createVault(USER1, STRATEGY_NAME);
        AnalogVault(payable(vaultAddr)).transferOwnership(USER1);
        initializeStrategy(strategyAddr, vaultAddr);
        console.log("Created vault at:", vaultAddr);
        console.log("Created strategy at:", strategyAddr);
    }

    /**
     * @notice Test that we can deposit USDC directly without external swaps
     * The new depositExecute flow handles everything internally.
     */
    function test_deposit_usdc_directly_no_swap() public {
        (address vaultAddr, address strategyAddr) = deployVaultAndStrategy();
        AnalogVault vault = AnalogVault(payable(vaultAddr));

        // Verify pool tokens
        (address token0, address token1) = vault.wants();
        console.log("Vault token0:", token0);
        console.log("Vault token1:", token1);

        bool token0IsUSDC = token0 == USDC;
        bool token1IsUSDC = token1 == USDC;
        assertTrue(token0IsUSDC || token1IsUSDC, "One token should be USDC");

        // Fund USER1 with USDC
        uint256 depositAmount = 1000 * 1e6;
        deal(USDC, USER1, depositAmount, true);

        // Check initial balances
        uint256 vaultUSDCBefore = IERC20(USDC).balanceOf(vaultAddr);
        console.log("Vault USDC balance before:", vaultUSDCBefore);

        // Step 1: User deposits USDC
        vm.startPrank(USER1);
        IERC20(USDC).approve(vaultAddr, depositAmount);
        vault.deposit(depositAmount);
        vm.stopPrank();

        // Verify USDC received by vault
        uint256 vaultUSDCAfter = IERC20(USDC).balanceOf(vaultAddr);
        assertEq(vaultUSDCAfter, depositAmount, "Vault should have received USDC");

        // Step 2: Controller executes deposit (deploys to strategy)
        vm.prank(CONTROLLER);
        vault.depositExecute();

        // Check strategy balances after deployment
        IStrategyConcLiq strategy = IStrategyConcLiq(strategyAddr);
        (uint256 strategyBal0, uint256 strategyBal1) = strategy.balances();

        console.log("Strategy balances - token0:", strategyBal0, "token1:", strategyBal1);

        // Verify strategy received funds
        if (token0IsUSDC) {
            assertGt(strategyBal0, 0, "Strategy should have received USDC (token0)");
        } else {
            assertGt(strategyBal1, 0, "Strategy should have received USDC (token1)");
        }

        // Check if strategy positioned liquidity
        TestStrategyPassiveManagerUniswap strategyContract = TestStrategyPassiveManagerUniswap(strategyAddr);
        (int24 tickLowerMain, int24 tickUpperMain) = strategyContract.positionMain();
        console.log("Main position ticks:", vm.toString(tickLowerMain), "to", vm.toString(tickUpperMain));
        assertTrue(tickLowerMain != 0 || tickUpperMain != 0, "Main position should be set");

        console.log("Strategy successfully positioned liquidity with single-sided USDC deposit");
    }

    /**
     * @notice Test multiple deposits via the 2-step flow
     */
    function test_multiple_deposits() public {
        (address vaultAddr, address strategyAddr) = deployVaultAndStrategy();
        AnalogVault vault = AnalogVault(payable(vaultAddr));
        IStrategyConcLiq strategy = IStrategyConcLiq(strategyAddr);

        (address token0,) = vault.wants();
        bool token0IsUSDC = (token0 == USDC);

        // First deposit
        uint256 deposit1 = 500 * 1e6;
        deal(USDC, USER1, deposit1, true);

        vm.startPrank(USER1);
        IERC20(USDC).approve(vaultAddr, deposit1);
        vault.deposit(deposit1);
        vm.stopPrank();

        vm.prank(CONTROLLER);
        vault.depositExecute();

        (uint256 bal0_1, uint256 bal1_1) = strategy.balances();
        console.log("After first deposit - balance0:", bal0_1, "balance1:", bal1_1);

        vm.roll(block.number + 10);

        // Second deposit
        uint256 deposit2 = 300 * 1e6;
        deal(USDC, USER1, deposit2, true);

        vm.startPrank(USER1);
        IERC20(USDC).approve(vaultAddr, deposit2);
        vault.deposit(deposit2);
        vm.stopPrank();

        vm.prank(CONTROLLER);
        vault.depositExecute();

        (uint256 bal0_2, uint256 bal1_2) = strategy.balances();
        console.log("After second deposit - balance0:", bal0_2, "balance1:", bal1_2);

        // Verify balances increased
        if (token0IsUSDC) {
            assertGe(bal0_2, bal0_1, "Token0 balance should increase");
        } else {
            assertGe(bal1_2, bal1_1, "Token1 balance should increase");
        }

        console.log("Multiple deposits successful");
    }
}
