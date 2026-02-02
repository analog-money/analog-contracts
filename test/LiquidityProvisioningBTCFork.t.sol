// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {AnalogVault} from "../src/AnalogVault.sol";
import {AnalogVaultFactory} from "../src/AnalogVaultFactory.sol";
import {StrategyFactory} from "../src/StrategyFactory.sol";
import {SwapCall} from "../src/libraries/SwapExecutor.sol";
import {
    TestStrategyPassiveManagerUniswap
} from "../src/TestStrategyPassiveManagerUniswap.sol";
import {IStrategyConcLiq} from "beefy-zk/interfaces/beefy/IStrategyConcLiq.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    StratFeeManagerInitializable
} from "beefy-zk/strategies/StratFeeManagerInitializable.sol";
import "forge-std/console.sol";

/**
 * @title LiquidityProvisioningBTCForkTest
 * @notice Fork test for Liquidity Provisioning BTC strategy (USDC/cbBTC pool on Base)
 *
 * Tests the full flow for BTC liquidity provisioning:
 * 1. Deploy vault and strategy for USDC/cbBTC pool
 * 2. Deposit USDC to vault
 * 3. Deploy funds to strategy (swap USDC to pool tokens and deposit)
 * 4. Verify strategy state and balances
 *
 * To run this test:
 *   forge test --match-contract LiquidityProvisioningBTCForkTest -vvv --fork-url $BASE_HTTP_RPC_URL
 */
contract LiquidityProvisioningBTCForkTest is Test {
    // Base Mainnet addresses
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006; // WETH on Base

    // USDC/cbBTC Uniswap V3 pool on Base (0.05% fee tier)
    address constant POOL = 0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef;
    address constant QUOTER = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a; // Uniswap V3 Quoter V2
    address constant UNIROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481; // SwapRouter02

    // StrategyFactory address on Base (update with actual deployed address or deploy in test)
    address constant STRATEGY_FACTORY_ADDRESS = address(0); // Will deploy in setUp if zero

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

    // Pool tokens (will be discovered from pool)
    address token0;
    address token1;

    function setUp() public {
        // Fork Base mainnet
        string memory rpcUrl = "https://mainnet.base.org";
        try vm.envString("BASE_HTTP_RPC_URL") returns (string memory url) {
            rpcUrl = url;
        } catch {}
        vm.createSelectFork(rpcUrl);

        // Discover pool tokens from the live pool
        IUniswapV3Pool poolContract = IUniswapV3Pool(POOL);
        token0 = poolContract.token0();
        token1 = poolContract.token1();

        // Label addresses
        vm.label(USDC, "USDC");
        vm.label(WETH, "WETH");
        vm.label(POOL, "USDC_cbBTC_POOL");
        vm.label(QUOTER, "UNIV3_QUOTER");
        vm.label(UNIROUTER, "UNIROUTER");
        vm.label(token0, "TOKEN0");
        vm.label(token1, "TOKEN1");
        vm.label(CONTROLLER, "CONTROLLER");
        vm.label(USER1, "USER1");
        vm.label(STRATEGIST, "STRATEGIST");

        console.log("Pool token0:", token0);
        console.log("Pool token1:", token1);

        // Deploy StrategyFactory if not provided
        address strategyFactoryAddr = STRATEGY_FACTORY_ADDRESS;
        if (strategyFactoryAddr == address(0)) {
            // Deploy StrategyFactory for testing
            strategyFactory = new StrategyFactory(
                WETH, // native
                address(this), // keeper (test contract)
                address(this), // beefyFeeRecipient (test contract)
                address(0) // beefyFeeConfig (zero for now)
            );
            strategyFactoryAddr = address(strategyFactory);
            vm.label(strategyFactoryAddr, "STRATEGY_FACTORY");
            console.log("Deployed StrategyFactory at:", strategyFactoryAddr);
        } else {
            strategyFactory = StrategyFactory(strategyFactoryAddr);
            vm.label(strategyFactoryAddr, "STRATEGY_FACTORY");
        }

        // Deploy strategy implementation and register it
        strategyImplementation = new TestStrategyPassiveManagerUniswap();
        vm.label(address(strategyImplementation), "STRATEGY_IMPL");

        // Register strategy in factory (as owner/keeper)
        vm.prank(address(this));
        strategyFactory.addStrategy(
            STRATEGY_NAME,
            address(strategyImplementation)
        );
        console.log(
            "Registered strategy:",
            STRATEGY_NAME,
            "at",
            address(strategyImplementation)
        );

        // Deploy AnalogVault implementation
        AnalogVault vaultImplementation = new AnalogVault();
        vm.label(address(vaultImplementation), "ANALOG_VAULT_IMPL");
        console.log(
            "Deployed AnalogVault implementation at:",
            address(vaultImplementation)
        );

        // Deploy AnalogVaultFactory
        factory = new AnalogVaultFactory();
        vm.label(address(factory), "ANALOG_VAULT_FACTORY");

        // Give users some ETH for gas
        vm.deal(USER1, 10 ether);
    }

    /**
     * @notice Helper function to initialize a strategy with proper parameters
     * @param strategy Strategy address to initialize
     * @param vault Vault address (will be set as strategy's vault)
     */
    function initializeStrategy(address strategy, address vault) internal {
        // Prepare CommonAddresses struct
        StratFeeManagerInitializable.CommonAddresses
            memory commonAddresses = StratFeeManagerInitializable
                .CommonAddresses({
                    vault: vault,
                    unirouter: UNIROUTER,
                    strategist: STRATEGIST,
                    factory: address(strategyFactory)
                });

        // Position width: 60 means 60 * tickSpacing on each side (typical for Uniswap strategies)
        int24 positionWidth = 60;

        // Get pool tokens to determine correct order
        // Build swap paths for rewards
        // token0 -> WETH -> Native (WETH is native on Base)
        bytes memory lpToken0ToNativePath = "";
        if (token0 != WETH) {
            // Build path: token0 -> WETH (assuming 0.05% fee tier = 500)
            lpToken0ToNativePath = abi.encodePacked(
                token0,
                uint24(500), // fee (0.05%)
                WETH
            );
        }

        // token1 -> WETH -> Native (WETH is native on Base)
        bytes memory lpToken1ToNativePath = "";
        if (token1 != WETH) {
            // Build path: token1 -> WETH (assuming 0.05% fee tier = 500)
            lpToken1ToNativePath = abi.encodePacked(
                token1,
                uint24(500), // fee (0.05%)
                WETH
            );
        }

        // Initialize strategy
        TestStrategyPassiveManagerUniswap(strategy).initialize(
            POOL,
            QUOTER,
            positionWidth,
            lpToken0ToNativePath,
            lpToken1ToNativePath,
            commonAddresses
        );

        console.log("Initialized strategy at:", strategy);
    }

    function test_factory_deployment() public view {
        // Verify factory state
        assertEq(factory.usdc(), USDC, "USDC address should be set");
        assertEq(
            factory.strategyFactory(),
            address(strategyFactory),
            "StrategyFactory should be set"
        );
        assertEq(factory.controller(), CONTROLLER, "Controller should be set");
        assertEq(factory.getVaultCount(), 0, "Initial vault count should be 0");
    }

    function test_create_vault_for_user() public {
        string memory vaultName = "BTC Liquidity Provision Vault";
        string memory vaultSymbol = "BTC-LP";

        // Create vault and strategy
        (address vaultAddr, address strategyAddr) = factory.createVault(
            USER1,
            STRATEGY_NAME,
            vaultName,
            vaultSymbol
        );

        // Verify vault was created
        assertTrue(vaultAddr != address(0), "Vault should be created");
        assertTrue(strategyAddr != address(0), "Strategy should be created");
        assertEq(
            factory.getVault(USER1),
            vaultAddr,
            "Factory should track vault"
        );
        assertEq(factory.getVaultCount(), 1, "Vault count should be 1");

        // Verify vault state
        AnalogVault vault = AnalogVault(payable(vaultAddr));
        assertEq(vault.owner(), USER1, "Vault owner should be USER1");
        assertEq(
            vault.factory(),
            address(factory),
            "Vault factory should be set"
        );
        assertEq(vault.usdc(), USDC, "Vault USDC should be set");
        assertEq(
            vault.controller(),
            CONTROLLER,
            "Vault controller should be set"
        );

        // Verify vault is initialized (has strategy)
        IStrategyConcLiq vaultStrategy = vault.strategy();
        assertEq(
            address(vaultStrategy),
            strategyAddr,
            "Vault strategy should match"
        );

        // Initialize strategy with proper parameters
        initializeStrategy(strategyAddr, vaultAddr);

        console.log("Vault created at:", vaultAddr);
        console.log("Strategy created at:", strategyAddr);
    }

    function test_deposit_usdc_to_vault() public {
        // Create vault and strategy
        (address vaultAddr, address strategyAddr) = factory.createVault(
            USER1,
            STRATEGY_NAME,
            "BTC LP Vault",
            "BTC-LP"
        );

        // Initialize strategy
        initializeStrategy(strategyAddr, vaultAddr);

        AnalogVault vault = AnalogVault(payable(vaultAddr));

        // Fund USER1 with USDC
        uint256 depositAmount = 1000 * 10 ** 6; // 1000 USDC
        deal(USDC, USER1, depositAmount, true);

        // Deposit as USER1
        vm.startPrank(USER1);
        IERC20(USDC).approve(vaultAddr, depositAmount);
        vault.deposit(depositAmount);
        vm.stopPrank();

        // Verify deposit is pending
        (uint256 pendingAmount, bool isPending,,,,,,,,,,,,) = vault.getPendingStates();
        assertTrue(isPending, "Deposit should be pending");
        assertEq(pendingAmount, depositAmount, "Pending amount should match");

        console.log("Deposited:", depositAmount);
        console.log("Pending amount:", pendingAmount);
    }

    function test_vault_wants_returns_pool_tokens() public {
        // Create vault and strategy
        (address vaultAddr, address strategyAddr) = factory.createVault(
            USER1,
            STRATEGY_NAME,
            "BTC LP Vault",
            "BTC-LP"
        );

        // Initialize strategy
        initializeStrategy(strategyAddr, vaultAddr);

        AnalogVault vault = AnalogVault(payable(vaultAddr));

        // Get pool tokens from vault
        (address vaultToken0, address vaultToken1) = vault.wants();
        
        // Verify they match the pool tokens
        assertEq(vaultToken0, token0, "Vault token0 should match pool token0");
        assertEq(vaultToken1, token1, "Vault token1 should match pool token1");

        console.log("Vault token0:", vaultToken0);
        console.log("Vault token1:", vaultToken1);
        console.log("Pool token0:", token0);
        console.log("Pool token1:", token1);
    }

    function test_strategy_initialization() public {
        // Create vault and strategy
        (address vaultAddr, address strategyAddr) = factory.createVault(
            USER1,
            STRATEGY_NAME,
            "BTC LP Vault",
            "BTC-LP"
        );

        // Initialize strategy
        initializeStrategy(strategyAddr, vaultAddr);

        TestStrategyPassiveManagerUniswap strategy = TestStrategyPassiveManagerUniswap(strategyAddr);

        // Verify strategy is initialized
        assertEq(address(strategy.vault()), vaultAddr, "Strategy vault should be set");
        assertEq(strategy.pool(), POOL, "Strategy pool should be set");
        assertEq(strategy.quoter(), QUOTER, "Strategy quoter should be set");

        console.log("Strategy initialized successfully");
        console.log("Strategy pool:", strategy.pool());
        console.log("Strategy quoter:", strategy.quoter());
    }

    function test_full_cycle_deposit() public {
        // Step 1: Deploy vault and strategy
        (address vaultAddr, address strategyAddr) = factory.createVault(
            USER1,
            STRATEGY_NAME,
            "BTC LP Vault",
            "BTC-LP"
        );

        // Initialize strategy
        initializeStrategy(strategyAddr, vaultAddr);

        AnalogVault vault = AnalogVault(payable(vaultAddr));

        // Get pool tokens
        (address vaultToken0, address vaultToken1) = vault.wants();
        IERC20 token0Contract = IERC20(vaultToken0);
        IERC20 token1Contract = IERC20(vaultToken1);

        console.log("=== Step 1: Vault Deployed ===");
        console.log("Vault:", vaultAddr);
        console.log("Strategy:", strategyAddr);
        console.log("Token0:", vaultToken0);
        console.log("Token1:", vaultToken1);

        // Step 2: Deposit request
        uint256 depositAmount = 1000 * 10 ** 6; // 1000 USDC
        deal(USDC, USER1, depositAmount, true);

        uint256 userUSDCBefore = IERC20(USDC).balanceOf(USER1);

        vm.startPrank(USER1);
        IERC20(USDC).approve(vaultAddr, depositAmount);
        vault.deposit(depositAmount);
        vm.stopPrank();

        (uint256 pendingAmount, bool isPending,,,,,,,,,,,,) = vault.getPendingStates();
        assertTrue(isPending, "Deposit should be pending");
        assertEq(pendingAmount, depositAmount, "Pending amount should match");

        console.log("=== Step 2: Deposit Registered ===");
        console.log("Registered amount:", depositAmount);
        console.log("Pending:", isPending);

        // Verify vault has USDC
        uint256 vaultUSDC = IERC20(USDC).balanceOf(vaultAddr);
        assertEq(vaultUSDC, depositAmount, "Vault should hold deposited USDC");

        console.log("=== Test Complete ===");
        console.log("Vault USDC balance:", vaultUSDC);
    }
}

// Interface for Uniswap V3 Pool
interface IUniswapV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
}

