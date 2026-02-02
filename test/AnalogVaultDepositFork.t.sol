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

/**
 * @title AnalogVaultDepositForkTest
 * @notice Fork test to reproduce depositUSDC failure issue
 *
 * To run this test:
 *   forge test --match-contract AnalogVaultDepositForkTest -vvv --fork-url $BASE_HTTP_RPC_URL
 */
contract AnalogVaultDepositForkTest is Test {
    // Base Mainnet addresses
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006; // WETH on Base

    // Uniswap V3 addresses on Base
    address constant POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224; // USDC-WETH pool
    address constant QUOTER = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a; // Uniswap V3 Quoter V2
    address constant UNIROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481; // SwapRouter02

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

    // Vault address from user's call data
    address constant VAULT_ADDRESS = 0x3f5a57940Bb3c16d47E736B57955349790FF294b;

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
        vm.label(USER2, "USER2");
        vm.label(STRATEGIST, "STRATEGIST");
        vm.label(VAULT_ADDRESS, "VAULT_ADDRESS");

        // Deploy StrategyFactory if not provided
        strategyFactory = new StrategyFactory(
            WETH, // native
            address(this), // keeper (test contract)
            address(this), // beefyFeeRecipient (test contract)
            address(0) // beefyFeeConfig (zero for now)
        );
        vm.label(address(strategyFactory), "STRATEGY_FACTORY");
        console.log("Deployed StrategyFactory at:", address(strategyFactory));

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

    /**
     * @notice Test depositUSDC with the exact call data from the user's request
     * Call data: 0xf688bcfb00000000000000000000000000000000000000000000000000000000000186a0
     * Function: depositUSDC(uint256 amount)
     * Amount: 0x186a0 = 100000 (100000 USDC with 6 decimals = 0.1 USDC)
     */
    function test_deposit_usdc_with_exact_call_data() public {
        // Check if vault exists at the address
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(VAULT_ADDRESS)
        }

        if (codeSize == 0) {
            console.log("Vault does not exist at", VAULT_ADDRESS);
            console.log("Creating vault for USER1 first...");

            // Create vault and strategy
            (address vaultAddr, address strategyAddr) = factory.createVault(
                USER1,
                STRATEGY_NAME,
                "Test Vault",
                "TV"
            );

            console.log("Created vault at:", vaultAddr);
            console.log("Expected vault at:", VAULT_ADDRESS);

            // If vault address doesn't match, we need to check why
            if (vaultAddr != VAULT_ADDRESS) {
                console.log(
                    "WARNING: Created vault address doesn't match expected address"
                );
                console.log("This might be because:");
                console.log("1. Factory address is different");
                console.log("2. User address is different");
                console.log("3. USDC address is different");
            }

            // Initialize strategy
            initializeStrategy(strategyAddr, vaultAddr);

            // Use the created vault address for testing
            AnalogVault vault = AnalogVault(payable(vaultAddr));

            // Check vault owner
            address vaultOwner = vault.owner();
            console.log("Vault owner:", vaultOwner);
            console.log("USER1 address:", USER1);

            // Fund USER1 with USDC
            uint256 depositAmount = 100000; // 0.1 USDC (6 decimals)
            deal(USDC, USER1, depositAmount, true);

            // Try to deposit as USER1 (should work)
            vm.startPrank(USER1);
            IERC20(USDC).approve(vaultAddr, depositAmount);

            // Encode the exact call data from user's request
            bytes memory callData = abi.encodeWithSignature(
                "deposit(uint256,address)",
                depositAmount,
                USER1
            );
            console.log("Call data:", vm.toString(callData));

            // Try the deposit
            (bool success, bytes memory returnData) = address(vault).call(
                callData
            );

            if (!success) {
                console.log("Deposit failed!");
                console.log("Return data:", vm.toString(returnData));

                // Try to decode the error
                if (returnData.length >= 4) {
                    bytes4 errorSelector = bytes4(returnData);
                    console.log("Error selector:", vm.toString(errorSelector));

                    if (errorSelector == AnalogVault.OnlyOwner.selector) {
                        console.log(
                            "ERROR: OnlyVaultOwner - msg.sender is not the vault owner"
                        );
                        console.log("msg.sender:", USER1);
                        console.log("vaultOwner:", vaultOwner);
                    } else if (
                        errorSelector ==
                        AnalogVault.Insufficient.selector
                    ) {
                        console.log("ERROR: InsufficientBalance - amount is 0");
                    }
                }
            } else {
                console.log("Deposit succeeded!");
                uint256 vaultUSDCBalance = IERC20(USDC).balanceOf(vaultAddr);
                console.log("Vault USDC balance:", vaultUSDCBalance);
            }

            vm.stopPrank();
        } else {
            console.log("Vault exists at", VAULT_ADDRESS);

            // Try to interact with existing vault
            AnalogVault vault = AnalogVault(payable(VAULT_ADDRESS));

            // Check vault owner
            address vaultOwner = vault.owner();
            console.log("Vault owner:", vaultOwner);

            // Try to deposit as USER1 (might fail if USER1 is not the owner)
            uint256 depositAmount = 100000; // 0.1 USDC (6 decimals)
            deal(USDC, USER1, depositAmount, true);

            vm.startPrank(USER1);
            IERC20(USDC).approve(VAULT_ADDRESS, depositAmount);

            // Encode the exact call data
            bytes memory callData = abi.encodeWithSignature(
                "deposit(uint256,address)",
                depositAmount,
                USER1
            );
            console.log("Call data:", vm.toString(callData));

            // Try the deposit
            (bool success, bytes memory returnData) = address(vault).call(
                callData
            );

            if (!success) {
                console.log("Deposit failed!");
                console.log("Return data:", vm.toString(returnData));

                // Try to decode the error
                if (returnData.length >= 4) {
                    bytes4 errorSelector = bytes4(returnData);
                    console.log("Error selector:", vm.toString(errorSelector));

                    if (errorSelector == AnalogVault.OnlyOwner.selector) {
                        console.log(
                            "ERROR: OnlyVaultOwner - msg.sender is not the vault owner"
                        );
                        console.log("msg.sender:", USER1);
                        console.log("vaultOwner:", vaultOwner);
                        console.log(
                            "SOLUTION: The user making the deposit must be the vault owner"
                        );
                    }
                }
            } else {
                console.log("Deposit succeeded!");
            }

            vm.stopPrank();
        }
    }

    /**
     * @notice Test depositUSDC with wrong user (not vault owner)
     */
    function test_deposit_usdc_wrong_user() public {
        // Create vault and strategy for USER1
        (address vaultAddr, address strategyAddr) = factory.createVault(
            USER1,
            STRATEGY_NAME,
            "Test Vault",
            "TV"
        );

        // Initialize strategy
        initializeStrategy(strategyAddr, vaultAddr);

        AnalogVault vault = AnalogVault(payable(vaultAddr));

        // Fund USER2 with USDC (USER2 is NOT the vault owner)
        uint256 depositAmount = 100000; // 0.1 USDC
        deal(USDC, USER2, depositAmount, true);

        // Try to deposit as USER2 (should fail with OnlyVaultOwner)
        vm.startPrank(USER2);
        IERC20(USDC).approve(vaultAddr, depositAmount);

        vm.expectRevert("Ownable: caller is not the owner");
        vault.deposit(depositAmount);

        vm.stopPrank();

        console.log("Correctly reverted with OnlyVaultOwner error");
    }

    /**
     * @notice Test depositUSDC with correct user (vault owner)
     */
    function test_deposit_usdc_correct_user() public {
        // Create vault and strategy for USER1
        (address vaultAddr, address strategyAddr) = factory.createVault(
            USER1,
            STRATEGY_NAME,
            "Test Vault",
            "TV"
        );

        // Initialize strategy
        initializeStrategy(strategyAddr, vaultAddr);

        AnalogVault vault = AnalogVault(payable(vaultAddr));

        // Fund USER1 with USDC (USER1 IS the vault owner)
        uint256 depositAmount = 100000; // 0.1 USDC
        deal(USDC, USER1, depositAmount, true);

        // Deposit as USER1 (should succeed)
        vm.startPrank(USER1);
        IERC20(USDC).approve(vaultAddr, depositAmount);
        vault.deposit(depositAmount);
        vm.stopPrank();

        // Verify deposit is pending
        (uint256 pendingAmount, bool isPending,,,,,,,,,,,,) = vault.getPendingStates();
        assertTrue(isPending, "Deposit should be pending");
        assertEq(pendingAmount, depositAmount, "Pending amount should match");

        console.log("Deposit succeeded! Pending amount:", pendingAmount);

        // Note: Controller would call swapAndDeploy to complete the deposit
    }
}
