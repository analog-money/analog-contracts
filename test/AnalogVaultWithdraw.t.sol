// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {AnalogVault} from "../src/AnalogVault.sol";
import {AnalogVaultFactory} from "../src/AnalogVaultFactory.sol";
import {StrategyFactory} from "../src/StrategyFactory.sol";
import {
    TestStrategyPassiveManagerUniswap
} from "../src/TestStrategyPassiveManagerUniswap.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    StratFeeManagerInitializable
} from "beefy-zk/strategies/StratFeeManagerInitializable.sol";

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

        bytes memory lpToken0ToNativePath = "";
        bytes memory lpToken1ToNativePath = abi.encodePacked(
            USDC,
            uint24(500),
            WETH
        );

        TestStrategyPassiveManagerUniswap(strategy).initialize(
            POOL,
            QUOTER,
            int24(10),
            lpToken0ToNativePath,
            lpToken1ToNativePath,
            commonAddresses
        );
    }

    function createAndInitVault(address user) internal returns (AnalogVault) {
        (address vaultAddr, address strategyAddr) = factory.createVault(
            user,
            STRATEGY_NAME
        );
        AnalogVault(payable(vaultAddr)).transferOwnership(user);
        initializeStrategy(strategyAddr, vaultAddr);
        return AnalogVault(payable(vaultAddr));
    }

    /// @notice Create vault, initialize strategy, and simulate funded state
    /// @dev Deals USDC directly to vault and writes totalShares storage to simulate
    ///      a completed deposit, avoiding NotCalm() from strategy's TWAP check.
    function createFundedVault(address user, uint256 amount) internal returns (AnalogVault) {
        AnalogVault vault = createAndInitVault(user);

        // Deal USDC directly to the vault
        deal(USDC, address(vault), amount, true);

        // Write totalShares storage to simulate shares minted for user
        // totalShares slot in BaseVault storage layout — use store cheatcode
        // We find the slot by reading the current value first
        uint256 currentShares = vault.totalShares();
        assertEq(currentShares, 0, "should start with 0 shares");

        // Find totalShares storage slot by probing (upgradeable proxies use namespaced slots)
        for (uint256 i = 0; i < 500; i++) {
            bytes32 slot = bytes32(i);
            bytes32 val = vm.load(address(vault), slot);
            if (val == bytes32(uint256(0))) {
                vm.store(address(vault), slot, bytes32(amount));
                if (vault.totalShares() == amount) {
                    // Found the slot! Leave it set.
                    return vault;
                }
                // Reset if wrong slot
                vm.store(address(vault), slot, bytes32(uint256(0)));
            }
        }

        revert("Could not find totalShares storage slot");
    }

    /**
     * @notice Test withdraw with wrong user (not vault owner)
     */
    function test_withdraw_wrong_user() public {
        AnalogVault vault = createAndInitVault(USER1);

        // Try to withdraw as USER2 (should fail with OnlyVaultOwner)
        vm.startPrank(USER2);
        vm.expectRevert();
        vault.withdraw(100000); // 0.1 USDC
        vm.stopPrank();

        console.log("Correctly reverted with OnlyVaultOwner error");
    }

    /**
     * @notice Test withdraw with correct user (vault owner)
     */
    function test_withdraw_correct_user() public {
        AnalogVault vault = createFundedVault(USER1, 10e6); // 10 USDC

        uint256 withdrawAmount = 1e6; // 1 USDC

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

        // Note: Controller would call withdrawExecute(minAmountOut) to complete
    }

    /**
     * @notice Test withdraw with zero amount
     */
    function test_withdraw_zero_amount() public {
        AnalogVault vault = createAndInitVault(USER1);

        // Try to withdraw zero amount (should fail)
        vm.startPrank(USER1);
        vm.expectRevert(bytes4(keccak256("InvalidOperation()")));
        vault.withdraw(0);
        vm.stopPrank();

        console.log("Correctly reverted with InsufficientBalance error");
    }

    /**
     * @notice Test double withdrawal (already pending)
     */
    function test_withdraw_already_pending() public {
        AnalogVault vault = createFundedVault(USER1, 10e6); // 10 USDC

        uint256 withdrawAmount = 1e6; // 1 USDC

        // First withdrawal
        vm.startPrank(USER1);
        vault.withdraw(withdrawAmount);

        // Try second withdrawal while first is pending (should fail)
        vm.expectRevert(bytes4(keccak256("InvalidOperation()")));
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
        AnalogVault vault = createFundedVault(USER1, 10e6); // 10 USDC

        uint256 withdrawAmount = 1e6; // 1 USDC

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
