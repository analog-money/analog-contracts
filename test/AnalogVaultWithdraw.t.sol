// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {AnalogVault} from "../src/AnalogVault.sol";
import {AnalogVaultFactory} from "../src/AnalogVaultFactory.sol";
import {StrategyFactory} from "../src/StrategyFactory.sol";
import {
    TestStrategyPassiveManagerUniswap
} from "../src/TestStrategyPassiveManagerUniswap.sol";

/**
 * @title AnalogVaultWithdrawTest
 * @notice Test suite for AnalogVault withdraw functionality
 *
 * Tests the new withdraw API:
 * 1. User calls withdraw(usdcAmount)
 * 2. Controller calls executeWithdrawal()
 * 3. Controller calls executeSwap(swapCalls)
 *
 * To run this test:
 *   forge test --match-contract AnalogVaultWithdrawTest -vv
 */
contract AnalogVaultWithdrawTest is Test {
    // Base Mainnet addresses
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224; // USDC-WETH pool

    // Test addresses
    address constant CONTROLLER =
        address(0x1111111111111111111111111111111111111111);
    address constant USER1 =
        address(0x2222222222222222222222222222222222222222);
    address constant USER2 =
        address(0x3333333333333333333333333333333333333333);

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
        vm.label(CONTROLLER, "CONTROLLER");
        vm.label(USER1, "USER1");
        vm.label(USER2, "USER2");

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
    }

    /**
     * @notice Test withdraw with wrong user (not vault owner)
     */
    function test_withdraw_wrong_user() public {
        // Create vault
        (address vaultAddr, ) = factory.createVault(
            USER1,
            STRATEGY_NAME,
            "Test Vault",
            "TV"
        );

        AnalogVault vault = AnalogVault(payable(vaultAddr));

        // Try to withdraw as USER2 (should fail with OnlyVaultOwner)
        vm.startPrank(USER2);
        vm.expectRevert("Ownable: caller is not the owner");
        vault.withdraw(100000); // 0.1 USDC
        vm.stopPrank();

        console.log("Correctly reverted with OnlyVaultOwner error");
    }

    /**
     * @notice Test withdraw with correct user (vault owner)
     */
    function test_withdraw_correct_user() public {
        // Create vault
        (address vaultAddr, ) = factory.createVault(
            USER1,
            STRATEGY_NAME,
            "Test Vault",
            "TV"
        );

        AnalogVault vault = AnalogVault(payable(vaultAddr));

        uint256 withdrawAmount = 100000; // 0.1 USDC

        // Withdraw as USER1 (should succeed)
        vm.startPrank(USER1);
        vault.withdraw(withdrawAmount);
        vm.stopPrank();

        // Verify withdrawal is pending
        (,, uint256 pendingAmount, bool isPending,,,,,,,,,,) = vault.getPendingStates();
        assertTrue(isPending, "Withdrawal should be pending");
        assertEq(pendingAmount, withdrawAmount, "Pending amount should match");
        // Recipient is always the vault owner (USER1)

        console.log("Withdrawal succeeded! Pending amount:", pendingAmount);
        console.log("Recipient is vault owner (USER1)");

        // Note: Controller would call executeWithdrawal and executeSwap to complete
    }

    /**
     * @notice Test withdraw with zero amount
     */
    function test_withdraw_zero_amount() public {
        // Create vault
        (address vaultAddr, ) = factory.createVault(
            USER1,
            STRATEGY_NAME,
            "Test Vault",
            "TV"
        );

        AnalogVault vault = AnalogVault(payable(vaultAddr));

        // Try to withdraw zero amount (should fail)
        vm.startPrank(USER1);
        vm.expectRevert(AnalogVault.Insufficient.selector);
        vault.withdraw(0);
        vm.stopPrank();

        console.log("Correctly reverted with InsufficientBalance error");
    }

    /**
     * @notice Test double withdrawal (already pending)
     */
    function test_withdraw_already_pending() public {
        // Create vault
        (address vaultAddr, ) = factory.createVault(
            USER1,
            STRATEGY_NAME,
            "Test Vault",
            "TV"
        );

        AnalogVault vault = AnalogVault(payable(vaultAddr));

        uint256 withdrawAmount = 100000; // 0.1 USDC

        // First withdrawal
        vm.startPrank(USER1);
        vault.withdraw(withdrawAmount);

        // Try second withdrawal while first is pending (should fail)
        vm.expectRevert(AnalogVault.WithdrawPending.selector);
        vault.withdraw(withdrawAmount);
        vm.stopPrank();

        console.log(
            "Correctly reverted with WithdrawalAlreadyPending error"
        );
    }

    /**
     * @notice Test cancel withdrawal
     */
    function test_cancel_withdrawal() public {
        // Create vault
        (address vaultAddr, ) = factory.createVault(
            USER1,
            STRATEGY_NAME,
            "Test Vault",
            "TV"
        );

        AnalogVault vault = AnalogVault(payable(vaultAddr));

        uint256 withdrawAmount = 100000; // 0.1 USDC

        // Register withdrawal
        vm.startPrank(USER1);
        vault.withdraw(withdrawAmount);

        // Verify withdrawal is pending
        (,,, bool isPendingBefore,,,,,,,,,,) = vault.getPendingStates();
        assertTrue(isPendingBefore, "Withdrawal should be pending");

        // Cancel withdrawal (2 = withdraw flag)
        vault.cancel(2);

        // Verify withdrawal is no longer pending
        (,,, bool isPendingAfter,,,,,,,,,,) = vault.getPendingStates();
        assertFalse(isPendingAfter, "Withdrawal should not be pending");

        vm.stopPrank();

        console.log("Withdrawal successfully cancelled");
    }
}
