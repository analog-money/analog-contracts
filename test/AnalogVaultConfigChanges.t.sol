// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {AnalogVault} from "../src/AnalogVault.sol";
import {IHedgedVault} from "../src/interfaces/IHedgedVault.sol";
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
    event BatchConfigQueued(uint8 flags, int24 positionWidth, int56 deviation, uint32 twapInterval);
    event BatchConfigExec(uint8 flags, int24 positionWidth, int56 deviation, uint32 twapInterval);

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
     * Test 4: Queuing new single config overwrites existing single config
     */
    function test_queueOverwritesSingleConfig() public {
        vault.queueConfigChange(1, int256(int256(int24(50))));
        vault.queueConfigChange(2, int256(int56(200)));

        (uint8 changeType, int256 value, bool isPending) = vault.pendingConfig();
        assertEq(changeType, 2, "Should be overwritten to Deviation");
        assertEq(value, int256(int56(200)));
        assertTrue(isPending);
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
        vm.expectRevert(IHedgedVault.InvalidConfig.selector);
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

    // ─── BATCH CONFIG TESTS ──────────────────────────────────────────────

    /**
     * Test 10: Queue batch config change with all 3 params
     */
    function test_queueBatchAllParams() public {
        int24 width = int24(60);
        int56 dev = int56(150);
        uint32 twap = uint32(600);

        vm.expectEmit(true, true, true, true);
        emit BatchConfigQueued(7, width, dev, twap); // flags = 1|2|4 = 7

        vault.queueBatchConfigChange(width, true, dev, true, twap, true);

        (int24 pw, bool hw, int56 d, bool hd, uint32 ti, bool ht) = vault.pendingBatch();
        assertEq(pw, width);
        assertTrue(hw);
        assertEq(d, dev);
        assertTrue(hd);
        assertEq(ti, twap);
        assertTrue(ht);
    }

    /**
     * Test 11: Queue batch with only 2 params (width + twap)
     */
    function test_queueBatchPartial() public {
        vault.queueBatchConfigChange(int24(40), true, int56(0), false, uint32(300), true);

        (int24 pw, bool hw, , bool hd, uint32 ti, bool ht) = vault.pendingBatch();
        assertEq(pw, int24(40));
        assertTrue(hw);
        assertFalse(hd);
        assertEq(ti, uint32(300));
        assertTrue(ht);
    }

    /**
     * Test 12: Queuing batch overwrites existing single config
     */
    function test_queueBatchOverwritesSingleConfig() public {
        vault.queueConfigChange(1, int256(int256(int24(50))));

        vault.queueBatchConfigChange(int24(60), true, int56(0), false, uint32(0), false);

        // Single config should be cleared
        (, , bool isPending) = vault.pendingConfig();
        assertFalse(isPending, "Single config should be cleared");

        // Batch should be set
        (int24 pw, bool hw, , , , ) = vault.pendingBatch();
        assertEq(pw, int24(60));
        assertTrue(hw);
    }

    /**
     * Test 13: Queuing single overwrites existing batch config
     */
    function test_queueSingleOverwritesBatchConfig() public {
        vault.queueBatchConfigChange(int24(60), true, int56(0), false, uint32(0), false);

        vault.queueConfigChange(1, int256(int256(int24(50))));

        // Batch should be cleared
        (, bool hw, , bool hd, , bool ht) = vault.pendingBatch();
        assertFalse(hw);
        assertFalse(hd);
        assertFalse(ht);

        // Single config should be set
        (uint8 changeType, int256 value, bool isPending) = vault.pendingConfig();
        assertEq(changeType, 1);
        assertEq(value, int256(int256(int24(50))));
        assertTrue(isPending);
    }

    /**
     * Test 14: Queuing batch overwrites existing batch
     */
    function test_queueBatchOverwritesBatch() public {
        vault.queueBatchConfigChange(int24(60), true, int56(0), false, uint32(0), false);

        vault.queueBatchConfigChange(int24(70), true, int56(150), true, uint32(0), false);

        (int24 pw, bool hw, int56 d, bool hd, , ) = vault.pendingBatch();
        assertEq(pw, int24(70));
        assertTrue(hw);
        assertEq(d, int56(150));
        assertTrue(hd);
    }

    /**
     * Test 15: Batch with no flags reverts
     */
    function test_cannotQueueEmptyBatch() public {
        vm.expectRevert(IHedgedVault.InvalidConfig.selector);
        vault.queueBatchConfigChange(int24(0), false, int56(0), false, uint32(0), false);
    }

    /**
     * Test 16: Non-owner cannot queue batch
     */
    function test_nonOwnerCannotQueueBatch() public {
        vm.prank(nonOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        vault.queueBatchConfigChange(int24(60), true, int56(0), false, uint32(0), false);
    }

    /**
     * Test 17: Non-controller cannot execute batch
     */
    function test_nonControllerCannotExecuteBatch() public {
        vault.queueBatchConfigChange(int24(60), true, int56(0), false, uint32(0), false);

        vm.prank(nonOwner);
        vm.expectRevert(); // OnlyController
        vault.executeBatchConfigChange();
    }

    /**
     * Test 18: Cannot execute batch if nothing pending
     */
    function test_cannotExecuteBatchIfNothingPending() public {
        vm.prank(CONTROLLER);
        vm.expectRevert(AnalogVault.NoConfig.selector);
        vault.executeBatchConfigChange();
    }

    /**
     * Test 19: getPendingStates reports configPending=true for batch
     */
    function test_getPendingStatesReportsBatchPending() public {
        vault.queueBatchConfigChange(int24(60), true, int56(0), false, uint32(0), false);

        (,,,,,,,,,,, , , bool configPending) = vault.getPendingStates();
        assertTrue(configPending, "getPendingStates should report batch as pending");
    }

    // ─── OVERWRITE UNBLOCKS STUCK CONFIG TESTS ─────────────────────────

    /**
     * Test 20: Overwriting stuck batch with valid config unblocks the vault
     */
    function test_overwriteUnblocksStuckBatch() public {
        // Queue an invalid positionWidth=1 (would revert on execute)
        vault.queueBatchConfigChange(int24(1), true, int56(0), false, uint32(0), false);

        // Overwrite with valid positionWidth=5
        vault.queueBatchConfigChange(int24(5), true, int56(0), false, uint32(0), false);

        (int24 pw, bool hw, , , , ) = vault.pendingBatch();
        assertEq(pw, int24(5), "Should be overwritten to valid width");
        assertTrue(hw);
    }

    /**
     * Test 21: getPendingStates reflects overwritten config
     */
    function test_getPendingStatesAfterOverwrite() public {
        vault.queueBatchConfigChange(int24(1), true, int56(150), true, uint32(600), true);
        // Overwrite with single config — batch should be cleared
        vault.queueConfigChange(3, int256(uint256(uint32(300))));

        (,,,,,,,,,,, , , bool configPending) = vault.getPendingStates();
        assertTrue(configPending, "Single config should show as pending");

        // Verify batch is gone
        (, bool hw, , bool hd, , bool ht) = vault.pendingBatch();
        assertFalse(hw);
        assertFalse(hd);
        assertFalse(ht);
    }
}
