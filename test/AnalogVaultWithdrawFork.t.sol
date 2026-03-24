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
 * @title AnalogVaultWithdrawForkTest
 * @notice Fork test for AnalogVault withdrawal flow
 *
 * Tests the two-step withdrawal flow:
 * 1. User calls withdraw(usdcAmount)
 * 2. Controller calls withdrawExecute(minAmountOut)
 *
 * To run this test:
 *   forge test --match-contract AnalogVaultWithdrawForkTest -vvv --fork-url $BASE_HTTP_RPC_URL
 */
contract AnalogVaultWithdrawForkTest is Test {
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
        AnalogVault vaultImplementation = new AnalogVault(USDC);

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
        bytes memory lpToken0ToNativePath = "";
        bytes memory lpToken1ToNativePath = abi.encodePacked(
            USDC,
            uint24(500),
            WETH
        );

        TestStrategyPassiveManagerUniswap strat = TestStrategyPassiveManagerUniswap(strategy);
        strat.initialize(
            POOL,
            QUOTER,
            positionWidth,
            lpToken0ToNativePath,
            lpToken1ToNativePath,
            commonAddresses
        );

        // Set maxTickDeviation so isCalm() returns true on fork
        strat.setDeviation(int56(39));
    }

    /// @notice Helper: create vault, initialize strategy, deposit, and execute deposit
    function _setupVaultWithDeposit(uint256 depositAmount) internal returns (AnalogVault vault, address vaultAddr, address strategyAddr) {
        (vaultAddr, strategyAddr) = factory.createVault(USER1, STRATEGY_NAME);
        AnalogVault(payable(vaultAddr)).transferOwnership(USER1);
        vault = AnalogVault(payable(vaultAddr));
        vm.label(vaultAddr, "VAULT");
        vm.label(strategyAddr, "STRATEGY");

        initializeStrategy(strategyAddr, vaultAddr);

        vm.roll(block.number + 1);

        // Fund and deposit
        deal(USDC, USER1, depositAmount, true);
        vm.startPrank(USER1);
        IERC20(USDC).approve(vaultAddr, depositAmount);
        vault.deposit(depositAmount);
        vm.stopPrank();

        // Controller executes deposit
        vm.prank(CONTROLLER);
        vault.depositExecute();

        vm.roll(block.number + 10);
    }

    /**
     * @notice Test full withdrawal flow: withdraw → withdrawExecute
     */
    function test_withdraw_full_flow() public {
        uint256 depositAmount = 1000 * 1e6;
        (AnalogVault vault,,) = _setupVaultWithDeposit(depositAmount);

        console.log("=== Test: Full withdraw flow ===");

        // Check balances after deposit
        (uint256 bal0, uint256 bal1) = vault.balances();
        console.log("Strategy balances - token0:", bal0, "token1:", bal1);

        // Step 1: User registers withdrawal
        uint256 withdrawAmount = 500 * 1e6;
        vm.prank(USER1);
        vault.withdraw(withdrawAmount);

        // Verify withdrawal is pending
        (
            ,
            ,
            uint256 pendingWithdraw,
            bool withdrawPending,
            ,,,,,,,,,
        ) = vault.getPendingStates();
        assertTrue(withdrawPending, "Withdrawal should be pending");
        assertEq(pendingWithdraw, withdrawAmount, "Pending amount should match");

        console.log("Registered withdrawal of", withdrawAmount / 1e6, "USDC");

        // Step 2: Controller executes withdrawal (withdraws from AMM, swaps to USDC, sends to user)
        uint256 userUSDCBefore = IERC20(USDC).balanceOf(USER1);

        vm.prank(CONTROLLER);
        vault.withdrawExecute(0); // minAmountOut = 0 for testing

        uint256 userUSDCAfter = IERC20(USDC).balanceOf(USER1);
        console.log("User received USDC:", userUSDCAfter - userUSDCBefore);

        // Verify user received USDC
        assertGt(userUSDCAfter, userUSDCBefore, "User should receive USDC");

        // Verify no pending operations
        (,,, bool stillPending,,,,,,,,,,) = vault.getPendingStates();
        assertFalse(stillPending, "Withdrawal should no longer be pending");

        console.log("=== Test completed ===");
    }

    /**
     * @notice Test withdrawExecute when no withdrawal is pending (should revert)
     */
    function test_withdrawExecute_no_pending_withdrawal() public {
        console.log("=== Test: withdrawExecute with no pending withdrawal ===");

        (address vaultAddr,) = factory.createVault(USER1, STRATEGY_NAME);
        AnalogVault(payable(vaultAddr)).transferOwnership(USER1);
        AnalogVault vault = AnalogVault(payable(vaultAddr));
        initializeStrategy(address(vault.strategy()), vaultAddr);

        // Try to execute withdrawal when there's no pending withdrawal
        vm.prank(CONTROLLER);
        vm.expectRevert();
        vault.withdrawExecute(0);

        console.log("Correctly reverted");
    }

    /**
     * @notice Test withdrawal with zero strategy balance (idle USDC in vault)
     */
    function test_withdraw_zero_strategy_balance() public {
        console.log("=== Test: withdraw with zero strategy balance ===");

        (address vaultAddr,) = factory.createVault(USER1, STRATEGY_NAME);
        AnalogVault(payable(vaultAddr)).transferOwnership(USER1);
        AnalogVault vault = AnalogVault(payable(vaultAddr));
        initializeStrategy(address(vault.strategy()), vaultAddr);

        // Deposit but don't execute (USDC stays idle in vault)
        uint256 depositAmount = 100 * 1e6;
        deal(USDC, USER1, depositAmount, true);
        vm.startPrank(USER1);
        IERC20(USDC).approve(vaultAddr, depositAmount);
        vault.deposit(depositAmount);
        vm.stopPrank();

        // Execute deposit to get shares
        vm.prank(CONTROLLER);
        vault.depositExecute();

        // Now withdraw — strategy has zero balance, vault has idle USDC
        vm.prank(USER1);
        vault.withdraw(depositAmount);

        // Verify pending
        (,,uint256 pendingWithdraw, bool withdrawPending,,,,,,,,,,) = vault.getPendingStates();
        assertTrue(withdrawPending, "Withdrawal should be pending");
        console.log("Pending withdrawal amount:", pendingWithdraw);

        // Execute withdrawal
        uint256 userUSDCBefore = IERC20(USDC).balanceOf(USER1);
        vm.prank(CONTROLLER);
        vault.withdrawExecute(0);

        uint256 userUSDCAfter = IERC20(USDC).balanceOf(USER1);
        console.log("User received USDC:", userUSDCAfter - userUSDCBefore);
        assertGt(userUSDCAfter, userUSDCBefore, "User should receive USDC");
    }

    /**
     * @notice Test withdrawExecute with production vault addresses
     */
    function test_withdrawExecute_production_addresses() public {
        console.log("=== Test: withdrawExecute with production addresses ===");

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
        } catch {
            console.log("ERROR: Could not read controller");
        }

        // Check pending states
        try vault.getPendingStates() returns (
            uint256 depositAmount,
            bool depositPending,
            uint256 withdrawalAmount,
            bool withdrawalPending,
            uint256, uint256, address, bool,
            uint256, uint256, bool,
            uint8, int256, bool
        ) {
            console.log("Deposit pending:", depositPending, "amount:", depositAmount);
            console.log("Withdrawal pending:", withdrawalPending, "amount:", withdrawalAmount);

            if (!withdrawalPending) {
                console.log("No withdrawal is pending");
            }
        } catch {
            console.log("ERROR reading pending states");
        }

        // Try to execute withdrawal as the controller
        vm.startPrank(controllerAddress);
        try vault.withdrawExecute(0) {
            console.log("SUCCESS: withdrawExecute() succeeded");
        } catch Error(string memory reason) {
            console.log("REVERT:", reason);
        } catch (bytes memory lowLevelData) {
            console.log("REVERT (low-level):");
            console.logBytes(lowLevelData);
        }
        vm.stopPrank();
    }

    /**
     * @notice Test that only controller can call withdrawExecute
     */
    function test_only_controller_can_withdrawExecute() public {
        uint256 depositAmount = 100 * 1e6;
        (AnalogVault vault,,) = _setupVaultWithDeposit(depositAmount);

        // Register withdrawal
        vm.prank(USER1);
        vault.withdraw(depositAmount);

        // Try as non-controller (should revert)
        vm.prank(USER1);
        vm.expectRevert();
        vault.withdrawExecute(0);
    }

    /**
     * @notice Test minAmountOut slippage protection in withdrawExecute
     */
    function test_withdrawExecute_slippage_protection() public {
        uint256 depositAmount = 100 * 1e6;
        (AnalogVault vault,,) = _setupVaultWithDeposit(depositAmount);

        // Register withdrawal
        vm.prank(USER1);
        vault.withdraw(depositAmount);

        // Try with unreasonably high minAmountOut (should revert)
        vm.prank(CONTROLLER);
        vm.expectRevert();
        vault.withdrawExecute(type(uint256).max);
    }
}
