// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {AnalogVault} from "../src/AnalogVault.sol";

/**
 * @title AnalogVaultConfigChangesTest
 * @notice Test suite for AnalogVault config change queuing and execution
 * @dev Tests the new config change system that mitigates isCalm issues
 */
contract AnalogVaultConfigChangesTest is Test {
    AnalogVault public vault;

    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // Base USDC
    address public constant STRATEGY =
        0xb0Ff31fa6a28934a7985c05bcF53b5411d7BCDf0; // Example strategy (corrected checksum)
    address public constant CONTROLLER = address(0xC0C0);
    address public constant FACTORY = address(0xFACE);
    address public owner;
    address public nonOwner;

    // Events to test
    event ConfigQueued(
        AnalogVault.ConfigChangeType indexed changeType,
        int256 value
    );
    event ConfigExec(
        AnalogVault.ConfigChangeType indexed changeType,
        int256 value
    );

    function setUp() public {
        // Fork Base mainnet for initialization to work
        vm.createSelectFork("https://mainnet.base.org");

        // Set up test accounts
        owner = address(this);
        nonOwner = address(0xBAD);

        // Deploy vault (no constructor arguments for beacon proxy pattern)
        vault = new AnalogVault();

        // Initialize vault properly (normally done by factory through proxy)
        vault.initialize(STRATEGY, "Test Vault", "TV", CONTROLLER, owner);
    }

    /**
     * Test 1: Queue position width change as owner
     */
    function test_queuePositionWidthChange_asOwner() public {
        // Owner queues position width change
        int24 newWidth = int24(50);

        vm.expectEmit(true, true, true, true);
        emit ConfigQueued(
            AnalogVault.ConfigChangeType.PositionWidth,
            int256(int256(newWidth))
        );

        vault.queueConfigChange(
            AnalogVault.ConfigChangeType.PositionWidth,
            int256(int256(newWidth))
        );

        // Verify pending change
        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            AnalogVault.ConfigChangeType changeType,
            int256 value,
            bool isPending
        ) = vault.getPendingStates();

        assertEq(
            uint8(changeType),
            uint8(AnalogVault.ConfigChangeType.PositionWidth),
            "Change type should be PositionWidth"
        );
        assertEq(value, int256(int256(newWidth)), "Value should match");
        assertTrue(isPending, "Should be pending");
    }

    /**
     * Test 2: Queue deviation change as owner
     */
    function test_queueDeviationChange_asOwner() public {
        int56 newDeviation = int56(200);

        vm.expectEmit(true, true, true, true);
        emit ConfigQueued(
            AnalogVault.ConfigChangeType.Deviation,
            int256(newDeviation)
        );

        vault.queueConfigChange(
            AnalogVault.ConfigChangeType.Deviation,
            int256(newDeviation)
        );

        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            AnalogVault.ConfigChangeType changeType,
            int256 value,
            bool isPending
        ) = vault.getPendingStates();

        assertEq(
            uint8(changeType),
            uint8(AnalogVault.ConfigChangeType.Deviation),
            "Change type should be Deviation"
        );
        assertEq(value, int256(newDeviation), "Value should match");
        assertTrue(isPending, "Should be pending");
    }

    /**
     * Test 3: Queue TWAP interval change as owner
     */
    function test_queueTwapIntervalChange_asOwner() public {
        uint32 newInterval = uint32(300);

        vm.expectEmit(true, true, true, true);
        emit ConfigQueued(
            AnalogVault.ConfigChangeType.TwapInterval,
            int256(uint256(newInterval))
        );

        vault.queueConfigChange(
            AnalogVault.ConfigChangeType.TwapInterval,
            int256(uint256(newInterval))
        );

        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            AnalogVault.ConfigChangeType changeType,
            int256 value,
            bool isPending
        ) = vault.getPendingStates();

        assertEq(
            uint8(changeType),
            uint8(AnalogVault.ConfigChangeType.TwapInterval),
            "Change type should be TwapInterval"
        );
        assertEq(value, int256(uint256(newInterval)), "Value should match");
        assertTrue(isPending, "Should be pending");
    }

    /**
     * Test 4: Cannot queue if change already pending
     */
    function test_cannotQueueMultipleChanges() public {
        // Queue first change
        vault.queueConfigChange(
            AnalogVault.ConfigChangeType.PositionWidth,
            int256(int256(int24(50)))
        );

        // Try to queue second change - should revert
        vm.expectRevert(AnalogVault.ConfigPending.selector);
        vault.queueConfigChange(
            AnalogVault.ConfigChangeType.Deviation,
            int256(int56(200))
        );
    }

    /**
     * Test 5: Non-owner cannot queue changes
     */
    function test_nonOwnerCannotQueueChanges() public {
        // Try as non-owner
        vm.prank(nonOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        vault.queueConfigChange(
            AnalogVault.ConfigChangeType.PositionWidth,
            int256(int256(int24(50)))
        );
    }

    /**
     * Test 6: Non-controller cannot execute config change
     */
    function test_nonControllerCannotExecute() public {
        // Queue change
        vault.queueConfigChange(
            AnalogVault.ConfigChangeType.PositionWidth,
            int256(int256(int24(50)))
        );

        // Try to execute as non-controller
        vm.prank(nonOwner);
        vm.expectRevert(AnalogVault.OnlyCtrl.selector);
        vault.executeConfigChange();
    }

    /**
     * Test 7: Cannot execute if nothing pending
     */
    function test_cannotExecuteIfNothingPending() public {
        vm.prank(CONTROLLER);
        vm.expectRevert(AnalogVault.NoConfig.selector);
        vault.executeConfigChange();
    }

    /**
     * Test 8: Get pending config when none exists
     */
    function test_getPendingConfigWhenNone() public {
        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            AnalogVault.ConfigChangeType changeType,
            int256 value,
            bool isPending
        ) = vault.getPendingStates();

        assertEq(
            uint8(changeType),
            uint8(AnalogVault.ConfigChangeType.None),
            "Should be None"
        );
        assertEq(value, 0, "Value should be 0");
        assertFalse(isPending, "Should not be pending");
    }
}
