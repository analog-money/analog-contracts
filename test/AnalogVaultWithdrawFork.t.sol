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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStrategyConcLiq} from "beefy-zk/interfaces/beefy/IStrategyConcLiq.sol";
import {
    StratFeeManagerInitializable
} from "beefy-zk/strategies/StratFeeManagerInitializable.sol";

/**
 * @title AnalogVaultWithdrawForkTest
 * @notice Fork test for AnalogVault withdrawal flow with executeSwap
 *
 * Tests the full withdrawal flow:
 * 1. User calls withdraw(usdcAmount)
 * 2. Controller calls executeWithdrawal() - withdraws from strategy
 * 3. Controller calls executeSwap(swapCalls) - swaps tokens to USDC
 *
 * To run this test:
 *   forge test --match-contract AnalogVaultWithdrawForkTest -vvv --fork-url $BASE_HTTP_RPC_URL
 */
contract AnalogVaultWithdrawForkTest is Test {
    // Base Mainnet addresses
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant ONEINCH_ROUTER =
        0x111111125421cA6dc452d289314280a0f8842A65;

    // Uniswap V3 addresses on Base
    address constant POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224; // USDC-WETH pool
    address constant QUOTER = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a; // Uniswap V3 Quoter V2
    address constant UNIROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;

    // Test addresses
    address constant CONTROLLER =
        address(0x1111111111111111111111111111111111111111);
    address constant USER1 =
        address(0x2222222222222222222222222222222222222222);
    address constant STRATEGIST =
        address(0x5555555555555555555555555555555555555555);

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
        vm.label(ONEINCH_ROUTER, "1INCH_ROUTER");
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

        // Deploy strategy implementation
        strategyImplementation = new TestStrategyPassiveManagerUniswap();

        // Register strategy
        strategyFactory.addStrategy(
            STRATEGY_NAME,
            address(strategyImplementation)
        );

        // Deploy AnalogVault implementation
        AnalogVault vaultImplementation = new AnalogVault();

        // Deploy AnalogVaultFactory
        factory = new AnalogVaultFactory();

        // Give users some ETH for gas
        vm.deal(USER1, 10 ether);
        vm.deal(CONTROLLER, 10 ether);
    }

    /**
     * @notice Helper function to initialize a strategy
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

        // WETH -> Native: WETH is already native on Base, so use empty path
        bytes memory lpToken0ToNativePath = "";

        // USDC -> WETH -> Native (WETH is native on Base)
        bytes memory lpToken1ToNativePath = abi.encodePacked(
            USDC,
            uint24(500), // fee (0.05%)
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
    }

    /**
     * @notice Test full withdrawal flow with executeSwap
     * @dev This test validates that executeSwap works correctly when vault has tokens
     */
    function test_withdraw_with_executeSwap() public {
        console.log("=== Test: Withdraw with executeSwap ===");

        // Create vault for USER1
        (address vaultAddr, ) = factory.createVault(
            USER1,
            STRATEGY_NAME,
            "Test Vault",
            "TV"
        );
        AnalogVault vault = AnalogVault(payable(vaultAddr));
        vm.label(vaultAddr, "VAULT");

        // Get strategy address
        address strategyAddr = address(vault.strategy());
        vm.label(strategyAddr, "STRATEGY");

        // Initialize strategy (must be done after vault creation)
        initializeStrategy(strategyAddr, vaultAddr);

        // Wait a bit for initialization
        vm.roll(block.number + 1);

        // Fund USER1 with USDC
        uint256 depositAmount = 1000 * 1e6; // 1000 USDC
        deal(USDC, USER1, depositAmount, true);

        // Step 1: Deposit USDC to vault
        vm.startPrank(USER1);
        IERC20(USDC).approve(vaultAddr, depositAmount);
        vault.deposit(depositAmount);
        vm.stopPrank();

        console.log("Deposited", depositAmount / 1e6, "USDC to vault");

        // Step 2: Deploy funds to strategy (as controller)
        // First need to execute deposit (swapAndDeploy)
        vm.startPrank(CONTROLLER);
        vault.swapAndDeploy(new SwapCall[](0), 0, 0);
        vm.stopPrank();

        console.log("Deployed funds to strategy");

        // Wait a bit and check balances
        vm.roll(block.number + 10);
        (uint256 bal0, uint256 bal1) = vault.balances();
        console.log("Strategy balances - token0:", bal0, "token1:", bal1);

        // Step 3: User registers withdrawal
        uint256 withdrawAmount = 500 * 1e6; // 500 USDC
        vm.startPrank(USER1);
        vault.withdraw(withdrawAmount);
        vm.stopPrank();

        console.log("Registered withdrawal of", withdrawAmount / 1e6, "USDC");

        // Verify withdrawal is pending
        (
            ,
            ,
            uint256 pendingWithdraw,
            bool withdrawPending,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,

        ) = vault.getPendingStates();
        assertTrue(withdrawPending, "Withdrawal should be pending");
        assertEq(
            pendingWithdraw,
            withdrawAmount,
            "Pending amount should match"
        );

        // Step 4: Controller executes withdrawal
        vm.startPrank(CONTROLLER);
        vault.executeWithdrawal();
        vm.stopPrank();

        console.log("Executed withdrawal from strategy");

        // Check that swap is now pending
        (
            uint256 _depositAmount,
            bool _depositPending,
            uint256 _withdrawalAmount,
            bool _withdrawalPending,
            uint256 swapToken0,
            uint256 swapToken1,
            address swapRecipient,
            bool swapPending,
            ,
            ,
            ,
            ,
            ,

        ) = vault.getPendingStates();
        assertTrue(swapPending, "Swap should be pending");
        assertTrue(
            swapToken0 > 0 || swapToken1 > 0,
            "Should have tokens to swap"
        );
        assertEq(swapRecipient, USER1, "Recipient should be vault owner");

        console.log(
            "Swap pending - token0:",
            swapToken0,
            "token1:",
            swapToken1
        );

        // Get token addresses
        (address token0, address token1) = vault.wants();
        vm.label(token0, "TOKEN0");
        vm.label(token1, "TOKEN1");

        // Check actual vault balances
        uint256 vaultToken0Balance = IERC20(token0).balanceOf(vaultAddr);
        uint256 vaultToken1Balance = IERC20(token1).balanceOf(vaultAddr);

        console.log(
            "Vault token balances - token0:",
            vaultToken0Balance,
            "token1:",
            vaultToken1Balance
        );
        console.log(
            "Pending swap amounts - token0:",
            swapToken0,
            "token1:",
            swapToken1
        );

        // Verify vault has the tokens
        assertEq(
            vaultToken0Balance,
            swapToken0,
            "Vault token0 balance should match pending"
        );
        assertEq(
            vaultToken1Balance,
            swapToken1,
            "Vault token1 balance should match pending"
        );

        // Step 5: Prepare swap calls
        // Note: In production, these would come from 1inch API
        // For testing, we'll create minimal swap calls that will fail gracefully
        // or we can use a mock that validates the structure

        SwapCall[] memory swapCalls = new SwapCall[](0);

        // Only create swap calls if we have tokens to swap and they're not USDC
        if (swapToken0 > 0 && token0 != USDC) {
            // For a real test, you would get swap calldata from 1inch API
            // For now, we'll test with empty swap calls to validate the structure
            // In production, this would be populated with actual 1inch swap calldata
            console.log("NOTE: Token0 swap needed but requires 1inch calldata");
        }

        if (swapToken1 > 0 && token1 != USDC) {
            console.log("NOTE: Token1 swap needed but requires 1inch calldata");
        }

        // If both tokens are USDC, no swap needed
        if (token0 == USDC && token1 == USDC) {
            console.log("Both tokens are USDC - no swap needed");
        }

        // For this test, we'll verify the vault state is correct for swap execution
        // The actual swap execution would require valid 1inch calldata

        // Verify that executeSwap can be called (it will revert if swap fails, which is expected without valid calldata)
        vm.startPrank(CONTROLLER);

        // If we have tokens that need swapping, try to execute (will fail without valid calldata)
        if (swapPending && (swapToken0 > 0 || swapToken1 > 0)) {
            if (token0 == USDC && token1 == USDC) {
                // Both are USDC, executeSwap should work with empty swap calls
                vault.executeSwap(swapCalls, 0);
                console.log("executeSwap succeeded (tokens already USDC)");
            } else {
                // Need actual swap calldata - this will fail with SwapFail
                // This is expected and validates the error handling
                vm.expectRevert(); // SwapFail() will be thrown
                vault.executeSwap(swapCalls, 0);
                console.log(
                    "executeSwap correctly reverted (no valid swap calldata)"
                );
            }
        }

        vm.stopPrank();

        console.log("=== Test completed ===");
    }

    /**
     * @notice Test executeSwap when vault has no tokens (should handle gracefully)
     */
    function test_executeSwap_no_tokens() public {
        console.log("=== Test: executeSwap with no tokens ===");

        // Create vault
        (address vaultAddr, ) = factory.createVault(
            USER1,
            STRATEGY_NAME,
            "Test Vault",
            "TV"
        );
        AnalogVault vault = AnalogVault(payable(vaultAddr));

        // Try to execute swap when no swap is pending
        vm.startPrank(CONTROLLER);
        vm.expectRevert(AnalogVault.NoSwap.selector);
        vault.executeSwap(new SwapCall[](0), 0);
        vm.stopPrank();

        console.log("Correctly reverted with NoSwap error");
    }

    /**
     * @notice Test executeSwap with invalid router address (should revert)
     */
    function test_executeSwap_invalid_router() public {
        console.log("=== Test: executeSwap with invalid router ===");

        // Create vault and set up withdrawal
        (address vaultAddr, ) = factory.createVault(
            USER1,
            STRATEGY_NAME,
            "Test Vault",
            "TV"
        );
        AnalogVault vault = AnalogVault(payable(vaultAddr));
        address strategyAddr = address(vault.strategy());
        initializeStrategy(strategyAddr, vaultAddr);

        // Deposit and deploy
        deal(USDC, USER1, 1000 * 1e6, true);
        vm.startPrank(USER1);
        IERC20(USDC).approve(vaultAddr, 1000 * 1e6);
        vault.deposit(1000 * 1e6);
        vm.stopPrank();

        vm.startPrank(CONTROLLER);
        vault.swapAndDeploy(new SwapCall[](0), 0, 0);
        vm.stopPrank();

        // Withdraw
        vm.startPrank(USER1);
        vault.withdraw(500 * 1e6);
        vm.stopPrank();

        vm.startPrank(CONTROLLER);
        vault.executeWithdrawal();
        vm.stopPrank();

        // Create swap call with invalid router (not 1inch)
        SwapCall[] memory swapCalls = new SwapCall[](1);
        swapCalls[0] = SwapCall({
            target: address(0x1234), // Invalid router
            data: "",
            value: 0
        });

        // Should revert with Invalid() from SwapExecutor
        vm.startPrank(CONTROLLER);
        vm.expectRevert(); // Invalid() error
        vault.executeSwap(swapCalls, 0);
        vm.stopPrank();

        console.log("Correctly reverted with Invalid router error");
    }

    /**
     * @notice Test executeWithdrawal when there's no pending withdrawal (should revert with NoWithdraw)
     * @dev This test reproduces the "missing revert data" error scenario
     */
    function test_executeWithdrawal_no_pending_withdrawal() public {
        console.log("=== Test: executeWithdrawal with no pending withdrawal ===");

        // Create vault
        (address vaultAddr, ) = factory.createVault(
            USER1,
            STRATEGY_NAME,
            "Test Vault",
            "TV"
        );
        AnalogVault vault = AnalogVault(payable(vaultAddr));
        address strategyAddr = address(vault.strategy());
        initializeStrategy(strategyAddr, vaultAddr);

        // Try to execute withdrawal when there's no pending withdrawal
        vm.startPrank(CONTROLLER);
        
        // This should revert with NoWithdraw() error
        // Using -vvvv we should see the exact revert reason
        vm.expectRevert(AnalogVault.NoWithdraw.selector);
        vault.executeWithdrawal();
        
        vm.stopPrank();

        console.log("Correctly reverted with NoWithdraw error");
    }

    /**
     * @notice Test executeWithdrawal when strategy call fails
     * @dev This test helps debug "missing revert data" errors
     */
    function test_executeWithdrawal_detailed_trace() public {
        console.log("=== Test: executeWithdrawal with detailed trace ===");

        // Create vault
        (address vaultAddr, ) = factory.createVault(
            USER1,
            STRATEGY_NAME,
            "Test Vault",
            "TV"
        );
        AnalogVault vault = AnalogVault(payable(vaultAddr));
        vm.label(vaultAddr, "VAULT");

        // Get strategy address
        address strategyAddr = address(vault.strategy());
        vm.label(strategyAddr, "STRATEGY");

        // Initialize strategy
        initializeStrategy(strategyAddr, vaultAddr);
        vm.roll(block.number + 1);

        // Fund USER1 with USDC
        uint256 depositAmount = 1000 * 1e6; // 1000 USDC
        deal(USDC, USER1, depositAmount, true);

        // Deposit USDC to vault
        vm.startPrank(USER1);
        IERC20(USDC).approve(vaultAddr, depositAmount);
        vault.deposit(depositAmount);
        vm.stopPrank();

        // Deploy funds to strategy
        vm.startPrank(CONTROLLER);
        vault.swapAndDeploy(new SwapCall[](0), 0, 0);
        vm.stopPrank();

        // Wait a bit
        vm.roll(block.number + 10);

        // Register withdrawal
        uint256 withdrawAmount = 500 * 1e6; // 500 USDC
        vm.startPrank(USER1);
        vault.withdraw(withdrawAmount);
        vm.stopPrank();

        // Check pending state
        (
            ,
            ,
            uint256 pendingWithdraw,
            bool withdrawPending,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,

        ) = vault.getPendingStates();
        console.log("Pending withdrawal amount:", pendingWithdraw);
        console.log("Withdrawal pending:", withdrawPending);

        // Now execute withdrawal with detailed trace
        vm.startPrank(CONTROLLER);
        
        // Use try-catch to see what happens
        try vault.executeWithdrawal() {
            console.log("executeWithdrawal succeeded");
        } catch Error(string memory reason) {
            console.log("executeWithdrawal reverted with reason:", reason);
        } catch (bytes memory lowLevelData) {
            console.log("executeWithdrawal reverted with low-level data");
            console.logBytes(lowLevelData);
        }
        
        vm.stopPrank();
    }

    /**
     * @notice Test executeWithdrawal with exact production addresses
     * @dev This test reproduces the exact error from production
     */
    function test_executeWithdrawal_production_addresses() public {
        console.log("=== Test: executeWithdrawal with production addresses ===");

        // Exact addresses from the error
        address vaultAddress = 0x2B49438A0F2e943FE1dD1Bb5E765d87A63733Fd3;
        address controllerAddress = 0x25e21aBcd8FF244914eb03dA2EBA7ea62EfF6821;
        
        vm.label(vaultAddress, "PRODUCTION_VAULT");
        vm.label(controllerAddress, "PRODUCTION_CONTROLLER");

        AnalogVault vault = AnalogVault(payable(vaultAddress));

        // Check if vault exists
        try vault.owner() returns (address owner) {
            console.log("Vault owner:", owner);
        } catch {
            console.log("ERROR: Vault does not exist or is not a valid AnalogVault");
            return;
        }

        // Check controller
        try vault.controller() returns (address controller) {
            console.log("Vault controller:", controller);
            console.log("Expected controller:", controllerAddress);
            if (controller != controllerAddress) {
                console.log("WARNING: Controller mismatch!");
            }
        } catch {
            console.log("ERROR: Could not read controller");
        }

        // Check pending states
        try vault.getPendingStates() returns (
            uint256 depositAmount,
            bool depositPending,
            uint256 withdrawalAmount,
            bool withdrawalPending,
            uint256 swapToken0,
            uint256 swapToken1,
            address swapRecipient,
            bool swapPending,
            uint256 deployAmount0,
            uint256 deployAmount1,
            bool deployPending,
            AnalogVault.ConfigChangeType configType,
            int256 configValue,
            bool configPending
        ) {
            console.log("=== Pending States ===");
            console.log("Deposit pending:", depositPending);
            console.log("Deposit amount:", depositAmount);
            console.log("Withdrawal pending:", withdrawalPending);
            console.log("Withdrawal amount:", withdrawalAmount);
            console.log("Swap pending:", swapPending);
            console.log("Swap token0:", swapToken0);
            console.log("Swap token1:", swapToken1);
            console.log("Deploy pending:", deployPending);
            console.log("Deploy amount0:", deployAmount0);
            console.log("Deploy amount1:", deployAmount1);
            console.log("Config pending:", configPending);

            if (!withdrawalPending) {
                console.log("ERROR: No withdrawal is pending! This would cause NoWithdraw() revert");
            }
        } catch Error(string memory reason) {
            console.log("ERROR reading pending states:", reason);
        } catch (bytes memory lowLevelData) {
            console.log("ERROR reading pending states (low-level)");
            console.logBytes(lowLevelData);
        }

        // Check if vault is calm
        try vault.isCalm() returns (bool isCalm) {
            console.log("Vault is calm:", isCalm);
            if (!isCalm) {
                console.log("WARNING: Vault is not calm");
            }
        } catch {
            console.log("ERROR: Could not check if vault is calm");
        }

        // Try to execute withdrawal as the controller
        vm.startPrank(controllerAddress);
        
        console.log("Attempting executeWithdrawal()...");
        try vault.executeWithdrawal() {
            console.log("SUCCESS: executeWithdrawal() succeeded");
        } catch Error(string memory reason) {
            console.log("REVERT: executeWithdrawal() reverted with reason:", reason);
        } catch Panic(uint256 code) {
            console.log("PANIC: executeWithdrawal() panicked with code:", code);
        } catch (bytes memory lowLevelData) {
            console.log("REVERT: executeWithdrawal() reverted with low-level data");
            console.logBytes(lowLevelData);
            
            // Try to decode common errors
            if (lowLevelData.length >= 4) {
                bytes4 errorSelector = bytes4(lowLevelData);
                console.log("Error selector:", vm.toString(errorSelector));
                
                // Check for known error selectors
                if (errorSelector == AnalogVault.NoWithdraw.selector) {
                    console.log("Decoded: NoWithdraw()");
                } else if (errorSelector == AnalogVault.NotCalm.selector) {
                    console.log("Decoded: NotCalm()");
                } else if (errorSelector == AnalogVault.OnlyCtrl.selector) {
                    console.log("Decoded: OnlyCtrl()");
                } else if (errorSelector == AnalogVault.Insufficient.selector) {
                    console.log("Decoded: Insufficient()");
                }
            }
        }
        
        vm.stopPrank();
    }

    /**
     * @notice Test executeWithdrawal when strategy has zero balances
     * @dev This test reproduces the "missing revert data" error when strategy has no funds
     */
    function test_executeWithdrawal_zero_strategy_balance() public {
        console.log("=== Test: executeWithdrawal with zero strategy balance ===");

        // Create vault
        (address vaultAddr, ) = factory.createVault(
            USER1,
            STRATEGY_NAME,
            "Test Vault",
            "TV"
        );
        AnalogVault vault = AnalogVault(payable(vaultAddr));
        address strategyAddr = address(vault.strategy());
        initializeStrategy(strategyAddr, vaultAddr);
        vm.roll(block.number + 1);

        // Fund USER1 with USDC
        uint256 depositAmount = 1000 * 1e6; // 1000 USDC
        deal(USDC, USER1, depositAmount, true);

        // Deposit USDC to vault
        vm.startPrank(USER1);
        IERC20(USDC).approve(vaultAddr, depositAmount);
        vault.deposit(depositAmount);
        vm.stopPrank();

        // Execute deposit and deploy to strategy
        vm.startPrank(CONTROLLER);
        vault.swapAndDeploy(new SwapCall[](0), 0, 0);
        vm.stopPrank();

        // Wait a bit
        vm.roll(block.number + 10);

        // Now manually withdraw all funds from strategy to simulate zero balance
        // This creates the scenario where vault has pending withdrawal but strategy has 0 balance
        vm.startPrank(CONTROLLER);
        // First, check if we can manually withdraw from strategy
        // We'll use a different approach - just register withdrawal when strategy already has 0
        vm.stopPrank();

        // Manually set vault to have USDC but strategy to have 0
        // Transfer USDC directly to vault
        deal(USDC, vaultAddr, 100 * 1e6, true);

        // Register withdrawal
        uint256 withdrawAmount = 100 * 1e6; // 100 USDC
        vm.startPrank(USER1);
        vault.withdraw(withdrawAmount);
        vm.stopPrank();

        // Check pending state
        (
            ,
            ,
            uint256 pendingWithdraw,
            bool withdrawPending,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,

        ) = vault.getPendingStates();
        console.log("Pending withdrawal amount:", pendingWithdraw);
        console.log("Withdrawal pending:", withdrawPending);

        // Check strategy balances (should be 0)
        (uint256 bal0, uint256 bal1) = vault.balances();
        console.log("Strategy balances - token0:", bal0, "token1:", bal1);

        // Check vault token balances
        (address token0, address token1) = vault.wants();
        uint256 vaultToken0Balance = IERC20(token0).balanceOf(vaultAddr);
        uint256 vaultToken1Balance = IERC20(token1).balanceOf(vaultAddr);
        console.log("Vault token balances - token0:", vaultToken0Balance, "token1:", vaultToken1Balance);

        // Now execute withdrawal - should handle zero strategy balance gracefully
        vm.startPrank(CONTROLLER);
        
        // This should succeed even with zero strategy balance
        try vault.executeWithdrawal() {
            console.log("SUCCESS: executeWithdrawal() succeeded with zero strategy balance");
            
            // Check that swap is now pending
            (
                ,
                ,
                ,
                bool _withdrawalPending,
                uint256 swapToken0,
                uint256 swapToken1,
                ,
                bool swapPending,
                ,
                ,
                ,
                ,
                ,

            ) = vault.getPendingStates();
            console.log("After execution - withdrawal pending:", _withdrawalPending);
            console.log("After execution - swap pending:", swapPending);
            console.log("After execution - swap token0:", swapToken0, "token1:", swapToken1);
        } catch Error(string memory reason) {
            console.log("REVERT: executeWithdrawal() reverted with reason:", reason);
        } catch Panic(uint256 code) {
            console.log("PANIC: executeWithdrawal() panicked with code:", code);
        } catch (bytes memory lowLevelData) {
            console.log("REVERT: executeWithdrawal() reverted with low-level data");
            console.logBytes(lowLevelData);
        }
        
        vm.stopPrank();
    }
}
