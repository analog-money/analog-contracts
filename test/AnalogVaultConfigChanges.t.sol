// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {AnalogVault} from "../src/AnalogVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title AnalogVaultConfigChangesTest
 * @notice Test suite for AnalogVault config change queuing and execution
 * @dev Tests the config change system (uint8 changeType: 1=PositionWidth, 2=Deviation, 3=TwapInterval)
 */
contract AnalogVaultConfigChangesTest is Test {
    AnalogVault public vault;

    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // Base USDC
    address public constant STRATEGY =
        0xb0Ff31fa6a28934a7985c05bcF53b5411d7BCDf0; // Example strategy
    address public constant CONTROLLER = address(0xC0C0);
    address public owner;
    address public nonOwner;

    // Events to test
    event ConfigQueued(uint8 indexed changeType, int256 value);
    event ConfigExec(uint8 indexed changeType, int256 value);

    function setUp() public {
        // Fork Base mainnet for initialization to work
        string memory rpcUrl = "https://api.developer.coinbase.com/rpc/v1/base/SF6TF2InaVNiSGPhP3Up4b62uEhp1qme";
        try vm.envString("BASE_HTTP_RPC_URL") returns (string memory url) {
            rpcUrl = url;
        } catch {}
        vm.createSelectFork(rpcUrl);

        // Set up test accounts
        owner = address(this);
        nonOwner = address(0xBAD);

        // Deploy vault behind proxy
        AnalogVault vaultImpl = new AnalogVault(USDC);
        bytes memory initData = abi.encodeWithSelector(
            bytes4(keccak256("initialize(address,address,address)")),
            owner,
            CONTROLLER,
            STRATEGY
        );
        vault = AnalogVault(payable(address(new ERC1967Proxy(address(vaultImpl), initData))));
    }

    /**
     * Test 1: Queue position width change as owner
     */
    function test_queuePositionWidthChange_asOwner() public {
        int24 newWidth = int24(50);

        vm.expectEmit(true, true, true, true);
        emit ConfigQueued(1, int256(int256(newWidth)));

        vault.queueConfigChange(1, int256(int256(newWidth)));

        // Verify pending change
        (uint8 changeType, int256 value, bool isPending) = vault.pendingConfig();
        assertEq(changeType, 1, "Change type should be PositionWidth (1)");
        assertEq(value, int256(int256(newWidth)), "Value should match");
        assertTrue(isPending, "Should be pending");
    }

    /**
     * Test 2: Queue deviation change as owner
     */
    function test_queueDeviationChange_asOwner() public {
        int56 newDeviation = int56(200);

        vm.expectEmit(true, true, true, true);
        emit ConfigQueued(2, int256(newDeviation));

        vault.queueConfigChange(2, int256(newDeviation));

        (uint8 changeType, int256 value, bool isPending) = vault.pendingConfig();
        assertEq(changeType, 2, "Change type should be Deviation (2)");
        assertEq(value, int256(newDeviation), "Value should match");
        assertTrue(isPending, "Should be pending");
    }

    /**
     * Test 3: Queue TWAP interval change as owner
     */
    function test_queueTwapIntervalChange_asOwner() public {
        uint32 newInterval = uint32(300);

        vm.expectEmit(true, true, true, true);
        emit ConfigQueued(3, int256(uint256(newInterval)));

        vault.queueConfigChange(3, int256(uint256(newInterval)));

        (uint8 changeType, int256 value, bool isPending) = vault.pendingConfig();
        assertEq(changeType, 3, "Change type should be TwapInterval (3)");
        assertEq(value, int256(uint256(newInterval)), "Value should match");
        assertTrue(isPending, "Should be pending");
    }

    /**
     * Test 4: Cannot queue if change already pending
     */
    function test_cannotQueueMultipleChanges() public {
        vault.queueConfigChange(1, int256(int256(int24(50))));

        vm.expectRevert(AnalogVault.ConfigPending.selector);
        vault.queueConfigChange(2, int256(int56(200)));
    }

    /**
     * Test 5: Non-owner cannot queue changes
     */
    function test_nonOwnerCannotQueueChanges() public {
        vm.prank(nonOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        vault.queueConfigChange(1, int256(int256(int24(50))));
    }

    /**
     * Test 6: Non-controller cannot execute config change
     */
    function test_nonControllerCannotExecute() public {
        vault.queueConfigChange(1, int256(int256(int24(50))));

        vm.prank(nonOwner);
        vm.expectRevert(); // OnlyController
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
     * Test 8: Invalid changeType (0) reverts
     */
    function test_cannotQueueInvalidChangeType() public {
        vm.expectRevert(AnalogVault.InvalidConfig.selector);
        vault.queueConfigChange(0, int256(100));
    }

    /**
     * Test 9: Get pending config when none exists
     */
    function test_getPendingConfigWhenNone() public view {
        (uint8 changeType, int256 value, bool isPending) = vault.pendingConfig();
        assertEq(changeType, 0, "Should be 0 (None)");
        assertEq(value, 0, "Value should be 0");
        assertFalse(isPending, "Should not be pending");
    }
}
