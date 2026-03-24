// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {AnalogVault} from "../src/AnalogVault.sol";
import {AnalogVaultFactory} from "../src/AnalogVaultFactory.sol";
import {StrategyFactory} from "../src/StrategyFactory.sol";
import {StratFeeManagerInitializable} from "beefy-zk/strategies/StratFeeManagerInitializable.sol";
import {
    TestStrategyPassiveManagerUniswap
} from "../src/TestStrategyPassiveManagerUniswap.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title AnalogVaultWithdrawTest
 * @notice Test suite for AnalogVault withdraw functionality
 *
 * Tests the 2-step withdraw API:
 * 1. User calls withdraw(usdcAmount)
 * 2. Controller calls withdrawExecute(minAmountOut)
 *
 * To run this test:
 *   forge test --match-contract AnalogVaultWithdrawTest -vv
 */
contract AnalogVaultWithdrawTest is Test {
    // Base Mainnet addresses
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224; // USDC-WETH pool
    address constant QUOTER = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a;
    address constant UNIROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant STRATEGIST = address(0x5555555555555555555555555555555555555555);

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
    }

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

        // WETH is token0 (= native), so empty path. USDC is token1, swap via 500bps pool to WETH.
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
    }

    function createVaultForUser(address user) internal returns (address vaultAddr, address strategyAddr) {
        (vaultAddr, strategyAddr) = factory.createVault(user, STRATEGY_NAME);
        initializeStrategy(strategyAddr, vaultAddr);
        // Widen deviation tolerance and mine blocks to settle TWAP oracle
        TestStrategyPassiveManagerUniswap(strategyAddr).setDeviation(int56(39));
        vm.roll(block.number + 600);
        vm.warp(block.timestamp + 600 * 2);
        AnalogVault(payable(vaultAddr)).transferOwnership(user);
    }

    /**
     * @notice Test withdraw with wrong user (not vault owner)
     */
    function test_withdraw_wrong_user() public {
        (address vaultAddr, ) = createVaultForUser(USER1);
        AnalogVault vault = AnalogVault(payable(vaultAddr));

        // Try to withdraw as USER2 (should fail with OnlyVaultOwner)
        vm.startPrank(USER2);
        vm.expectRevert();
        vault.withdraw(100000); // 0.1 USDC
        vm.stopPrank();
    }

    /**
     * @notice Test withdraw with correct user (vault owner)
     */
    function test_withdraw_correct_user() public {
        (address vaultAddr, ) = createVaultForUser(USER1);
        AnalogVault vault = AnalogVault(payable(vaultAddr));

        // First deposit so vault has equity
        uint256 depositAmount = 100 * 10 ** 6; // 100 USDC
        deal(USDC, USER1, depositAmount, true);
        vm.startPrank(USER1);
        IERC20(USDC).approve(vaultAddr, depositAmount);
        vault.deposit(depositAmount);

        // Execute deposit as controller to create shares
        vm.stopPrank();
        vm.prank(CONTROLLER);
        vault.depositExecute();

        // Now withdraw
        uint256 withdrawAmount = 50 * 10 ** 6; // 50 USDC
        vm.startPrank(USER1);
        vault.withdraw(withdrawAmount);
        vm.stopPrank();

        // Verify withdrawal is pending
        (,, uint256 pendingAmount, bool isPending,,,,,,,,,,) = vault.getPendingStates();
        assertTrue(isPending, "Withdrawal should be pending");
        assertEq(pendingAmount, withdrawAmount, "Pending amount should match");
    }

    /**
     * @notice Test withdraw with zero amount
     */
    function test_withdraw_zero_amount() public {
        (address vaultAddr, ) = createVaultForUser(USER1);
        AnalogVault vault = AnalogVault(payable(vaultAddr));

        // Try to withdraw zero amount (should fail)
        vm.startPrank(USER1);
        vm.expectRevert(bytes4(keccak256("InvalidOperation()")));
        vault.withdraw(0);
        vm.stopPrank();
    }

    /**
     * @notice Test double withdrawal (already pending)
     */
    function test_withdraw_already_pending() public {
        (address vaultAddr, ) = createVaultForUser(USER1);
        AnalogVault vault = AnalogVault(payable(vaultAddr));

        // Deposit first
        uint256 depositAmount = 100 * 10 ** 6;
        deal(USDC, USER1, depositAmount, true);
        vm.startPrank(USER1);
        IERC20(USDC).approve(vaultAddr, depositAmount);
        vault.deposit(depositAmount);
        vm.stopPrank();
        vm.prank(CONTROLLER);
        vault.depositExecute();

        uint256 withdrawAmount = 50 * 10 ** 6;

        // First withdrawal
        vm.startPrank(USER1);
        vault.withdraw(withdrawAmount);

        // Try second withdrawal while first is pending (should fail)
        vm.expectRevert(bytes4(keccak256("InvalidOperation()")));
        vault.withdraw(withdrawAmount);
        vm.stopPrank();
    }

    /**
     * @notice Test cancel withdrawal
     */
    function test_cancel_withdrawal() public {
        (address vaultAddr, ) = createVaultForUser(USER1);
        AnalogVault vault = AnalogVault(payable(vaultAddr));

        // Deposit first
        uint256 depositAmount = 100 * 10 ** 6;
        deal(USDC, USER1, depositAmount, true);
        vm.startPrank(USER1);
        IERC20(USDC).approve(vaultAddr, depositAmount);
        vault.deposit(depositAmount);
        vm.stopPrank();
        vm.prank(CONTROLLER);
        vault.depositExecute();

        uint256 withdrawAmount = 50 * 10 ** 6;

        // Register withdrawal
        vm.startPrank(USER1);
        vault.withdraw(withdrawAmount);

        // Verify withdrawal is pending
        (,,, bool isPendingBefore,,,,,,,,,,) = vault.getPendingStates();
        assertTrue(isPendingBefore, "Withdrawal should be pending");

        // Cancel withdrawal (2 = withdraw flag)
        vault.withdrawCancel();

        // Verify withdrawal is no longer pending
        (,,, bool isPendingAfter,,,,,,,,,,) = vault.getPendingStates();
        assertFalse(isPendingAfter, "Withdrawal should not be pending");

        vm.stopPrank();

        console.log("Withdrawal successfully cancelled");
    }
}
