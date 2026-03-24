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
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title AnalogVaultForkTest
 * @notice Fork test for AnalogVaultFactory and AnalogVault deployment and functionality
 *
 * To run this test:
 *   forge test --match-contract AnalogVaultForkTest -vvv --fork-url $BASE_HTTP_RPC_URL
 */
contract AnalogVaultForkTest is Test {
    // Base Mainnet addresses
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006; // WETH on Base

    // Uniswap V3 addresses on Base
    address constant POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224; // USDC-WETH pool
    address constant QUOTER = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a; // Uniswap V3 Quoter V2
    address constant UNIROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481; // SwapRouter02

    // StrategyFactory address on Base (update with actual deployed address or deploy in test)
    // Set to address(0) to deploy a new one in setUp
    address constant STRATEGY_FACTORY_ADDRESS = address(0); // Will deploy in setUp if zero

    // Test addresses
    address constant CONTROLLER =
        address(0x1111111111111111111111111111111111111111);
    address constant USER1 =
        address(0x2222222222222222222222222222222222222222);
    address constant USER2 =
        address(0x3333333333333333333333333333333333333333);
    address constant STRATEGIST =
        address(0x5555555555555555555555555555555555555555);

    // Strategy name for testing
    string constant STRATEGY_NAME = "TestStrategyPassiveManagerUniswap";

    AnalogVaultFactory factory;
    StrategyFactory strategyFactory;
    TestStrategyPassiveManagerUniswap strategyImplementation;

    function setUp() public {
        // Fork Base mainnet
        string memory rpcUrl = "https://api.developer.coinbase.com/rpc/v1/base/SF6TF2InaVNiSGPhP3Up4b62uEhp1qme";
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
        vm.label(USER2, "USER2");
        vm.label(STRATEGIST, "STRATEGIST");

        // Deploy StrategyFactory if not provided
        address strategyFactoryAddr = STRATEGY_FACTORY_ADDRESS;
        if (strategyFactoryAddr == address(0)) {
            // Deploy StrategyFactory for testing
            // Constructor: (native, keeper, beefyFeeRecipient, beefyFeeConfig)
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
        AnalogVault vaultImplementation = new AnalogVault(USDC);
        vm.label(address(vaultImplementation), "ANALOG_VAULT_IMPL");
        console.log(
            "Deployed AnalogVault implementation at:",
            address(vaultImplementation)
        );

        // Deploy AnalogVaultFactory behind proxy with initialization
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
        vm.deal(USER2, 10 ether);
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

        // Position width: 10 means 10 * tickSpacing on each side (typical for Uniswap strategies)
        int24 positionWidth = 10;

        // Get pool tokens to determine correct order
        // Note: Pool has WETH as token0 and USDC as token1
        // lpToken0 = WETH (pool.token0()) - WETH is native on Base
        // lpToken1 = USDC (pool.token1())

        // WETH -> Native: WETH is already native on Base, so use empty path
        bytes memory lpToken0ToNativePath = ""; // Empty path when token is already native

        // USDC -> WETH -> Native (WETH is native on Base)
        // Format: token (20 bytes) + fee (3 bytes) + token (20 bytes)
        // Fee 500 = 0.05%
        bytes memory lpToken1ToNativePath = abi.encodePacked(
            USDC, // token1 (USDC)
            uint24(500), // fee (0.05%)
            WETH // WETH (native on Base)
        );

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
        // Create vault and strategy
        (address vaultAddr, address strategyAddr) = factory.createVault(
            USER1,
            STRATEGY_NAME
        );
        AnalogVault(payable(vaultAddr)).transferOwnership(USER1);

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
        assertEq(vault.USDC(), USDC, "Vault USDC should be set");
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
            STRATEGY_NAME
        );
        AnalogVault(payable(vaultAddr)).transferOwnership(USER1);

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

    function test_only_owner_can_deposit_usdc() public {
        // Create vault and strategy
        (address vaultAddr, address strategyAddr) = factory.createVault(
            USER1,
            STRATEGY_NAME
        );
        AnalogVault(payable(vaultAddr)).transferOwnership(USER1);

        // Initialize strategy
        initializeStrategy(strategyAddr, vaultAddr);

        AnalogVault vault = AnalogVault(payable(vaultAddr));

        // Fund USER2 with USDC
        uint256 depositAmount = 1000 * 10 ** 6;
        deal(USDC, USER2, depositAmount, true);

        // Try to register deposit as USER2 (not owner)
        vm.startPrank(USER2);
        IERC20(USDC).approve(vaultAddr, depositAmount);
        vm.expectRevert();
        vault.deposit(depositAmount);
        vm.stopPrank();
    }

    function test_get_vault_shares() public {
        // Create vault and strategy
        (address vaultAddr, address strategyAddr) = factory.createVault(
            USER1,
            STRATEGY_NAME
        );
        AnalogVault(payable(vaultAddr)).transferOwnership(USER1);

        // Initialize strategy
        initializeStrategy(strategyAddr, vaultAddr);

        AnalogVault vault = AnalogVault(payable(vaultAddr));

        // Initially should have 0 balances
        (uint256 amount0, uint256 amount1) = vault.balances();
        assertEq(amount0, 0, "Initial token0 balance should be 0");
        assertEq(amount1, 0, "Initial token1 balance should be 0");

        console.log(
            "Initial vault balances - token0:",
            amount0,
            "token1:",
            amount1
        );
    }

    function test_update_controller() public {
        address newController = address(
            0x4444444444444444444444444444444444444444
        );

        // Update controller
        vm.prank(address(this)); // Test contract is owner
        factory.setController(newController);

        // Verify updated
        assertEq(
            factory.controller(),
            newController,
            "Controller should be updated"
        );
    }

    function test_owner_can_set_vault_controller() public {
        // Create vault and strategy
        (address vaultAddr, address strategyAddr) = factory.createVault(
            USER1,
            STRATEGY_NAME
        );
        AnalogVault(payable(vaultAddr)).transferOwnership(USER1);

        // Initialize strategy
        initializeStrategy(strategyAddr, vaultAddr);

        AnalogVault vault = AnalogVault(payable(vaultAddr));

        // Verify initial controller
        assertEq(
            vault.controller(),
            CONTROLLER,
            "Initial controller should be set"
        );

        // Vault owner (USER1) can update controller
        address newController = address(
            0x4444444444444444444444444444444444444444
        );
        vm.prank(USER1);
        vault.setController(newController);

        // Verify updated
        assertEq(
            vault.controller(),
            newController,
            "Vault controller should be updated"
        );
    }

    function test_factory_cannot_set_vault_controller() public {
        // Create vault and strategy
        (address vaultAddr, ) = factory.createVault(
            USER1,
            STRATEGY_NAME
        );
        AnalogVault(payable(vaultAddr)).transferOwnership(USER1);

        AnalogVault vault = AnalogVault(payable(vaultAddr));

        // Factory (address(this)) cannot update vault controller
        address newController = address(
            0x4444444444444444444444444444444444444444
        );
        vm.prank(address(factory));
        vm.expectRevert();
        vault.setController(newController);
    }

    function test_only_owner_can_update_controller() public {
        address newController = address(
            0x4444444444444444444444444444444444444444
        );

        // Try to update controller as non-owner
        vm.prank(USER1);
        vm.expectRevert();
        factory.setController(newController);
    }

    function test_cannot_set_zero_controller() public {
        vm.expectRevert(AnalogVaultFactory.InvalidController.selector);
        factory.setController(address(0));
    }

    /**
     * @notice Full cycle test: deploy vault, deposit USDC, deploy to strategy, then withdraw back to user
     * Uses the new 2-step API:
     * 1. Deploy vault + strategy
     * 2. User calls deposit(usdcAmount) → Controller calls depositExecute()
     * 3. User calls withdraw(usdcAmount) → Controller calls withdrawExecute(minAmountOut)
     */
    function test_full_cycle_deposit_deploy_withdraw() public {
        // Step 1: Deploy vault and strategy
        (address vaultAddr, address strategyAddr) = factory.createVault(
            USER1,
            STRATEGY_NAME
        );
        AnalogVault(payable(vaultAddr)).transferOwnership(USER1);

        // Initialize strategy with deviation set for fork
        initializeStrategy(strategyAddr, vaultAddr);
        TestStrategyPassiveManagerUniswap(strategyAddr).setDeviation(int56(39));

        AnalogVault vault = AnalogVault(payable(vaultAddr));

        console.log("=== Step 1: Vault Deployed ===");
        console.log("Vault:", vaultAddr);
        console.log("Strategy:", strategyAddr);

        // Step 2: Deposit USDC
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

        // Step 3: Controller executes deposit (deploys to strategy)
        vm.prank(CONTROLLER);
        vault.depositExecute();

        // Verify funds are deployed
        (uint256 bal0, uint256 bal1) = vault.balances();
        console.log("=== Step 3: Deployed to Strategy ===");
        console.log("Balance0:", bal0, "Balance1:", bal1);
        assertTrue(bal0 > 0 || bal1 > 0, "Strategy should have funds");

        // Verify shares were minted
        uint256 shares = vault.totalShares();
        assertGt(shares, 0, "Shares should be minted");
        console.log("Shares:", shares);

        vm.roll(block.number + 10);

        // Step 4: User registers withdrawal
        uint256 vaultEquity = vault.getVaultEquity();
        console.log("Vault equity:", vaultEquity);

        vm.prank(USER1);
        vault.withdraw(vaultEquity);

        console.log("=== Step 4: Withdrawal Registered ===");

        // Step 5: Controller executes withdrawal
        vm.prank(CONTROLLER);
        vault.withdrawExecute(0); // minAmountOut = 0 for testing

        uint256 userUSDCAfter = IERC20(USDC).balanceOf(USER1);
        console.log("=== Step 5: Withdrawn to User ===");
        console.log("User USDC before:", userUSDCBefore);
        console.log("User USDC after:", userUSDCAfter);

        // Verify user received USDC back (may be less due to swap slippage)
        assertGt(userUSDCAfter, 0, "User should receive USDC back");
    }
}

// Interface for Uniswap V3 Pool
interface IUniswapV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
}
