// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {AnalogVault} from "../src/AnalogVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DebugVaultFork is Test {
  address constant VAULT_ADDRESS = 0xBfc1eC955E6EccC7D06C10c32Ef45cA41FBDcbC2;
  // Use latest block - contract was deployed more recently
  uint256 constant BASE_FORK_BLOCK = 35_000_000; // More recent block

  AnalogVault vault;

  function setUp() public {
    // Use latest block - don't specify block number
    vm.createSelectFork(vm.envString("BASE_RPC_URL"));
    vault = AnalogVault(payable(VAULT_ADDRESS));
  }

  function testDebugVaultState() public view {
    console.log("=== Debugging Vault:", VAULT_ADDRESS);
    console.log("Block number:", block.number);
    console.log("");

    // 1. Get token addresses
    (address token0, address token1) = vault.wants();
    console.log("Token0:", token0);
    console.log("Token1:", token1);
    console.log("");

    // 2. Token info (decimals would require a different interface)
    console.log("Token0 address:", token0);
    console.log("Token1 address:", token1);
    console.log("");

    // 3. Get vault ERC20 balances
    uint256 vaultToken0Balance = IERC20(token0).balanceOf(VAULT_ADDRESS);
    uint256 vaultToken1Balance = IERC20(token1).balanceOf(VAULT_ADDRESS);
    console.log("=== Vault ERC20 Balances ===");
    console.log("Vault Token0 Balance:", vaultToken0Balance);
    console.log("Vault Token1 Balance:", vaultToken1Balance);
    console.log("");

    // 4. Get strategy address
    address strategyAddress = address(vault.strategy());
    console.log("=== Strategy Address ===");
    console.log("Strategy:", strategyAddress);
    console.log("");

    if (strategyAddress != address(0)) {
      // 5. Get strategy ERC20 balances
      uint256 strategyToken0Balance = IERC20(token0).balanceOf(strategyAddress);
      uint256 strategyToken1Balance = IERC20(token1).balanceOf(strategyAddress);
      console.log("=== Strategy ERC20 Balances ===");
      console.log("Strategy Token0 Balance:", strategyToken0Balance);
      console.log("Strategy Token1 Balance:", strategyToken1Balance);
      console.log("");

      // 6. Get Uniswap positions - call directly using staticcall
      (bool success, bytes memory returnData) = strategyAddress.staticcall(
        abi.encodeWithSignature("balancesOfPool()")
      );
      if (success && returnData.length > 0) {
        (
          uint256 token0Bal,
          uint256 token1Bal,
          uint256 mainAmount0,
          uint256 mainAmount1,
          uint256 altAmount0,
          uint256 altAmount1
        ) = abi.decode(returnData, (uint256, uint256, uint256, uint256, uint256, uint256));
        console.log("=== Uniswap Positions ===");
        console.log("Token0 Bal (idle):", token0Bal);
        console.log("Token1 Bal (idle):", token1Bal);
        console.log("Main Position Token0:", mainAmount0);
        console.log("Main Position Token1:", mainAmount1);
        console.log("Alt Position Token0:", altAmount0);
        console.log("Alt Position Token1:", altAmount1);
        console.log("Total Position Token0:", mainAmount0 + altAmount0);
        console.log("Total Position Token1:", mainAmount1 + altAmount1);
        console.log("");
      } else {
        console.log("ERROR getting balancesOfPool - call failed");
      }

      // Try using the return values if we got them
      if (success && returnData.length > 0) {
        try vault.balances() returns (uint256 bal0, uint256 bal1) {
          console.log("=== Vault.balances() ===");
          console.log("Balance0:", bal0);
          console.log("Balance1:", bal1);
          console.log("");
        } catch Error(string memory reason) {
          console.log("ERROR getting vault.balances():", reason);
        } catch (bytes memory lowLevelData) {
          console.log("ERROR getting vault.balances() (low-level)");
          console.logBytes(lowLevelData);
        }
      }
    }

    // 7. Try getPendingStates - use staticcall to avoid stack too deep
    console.log("=== getPendingStates() ===");
    console.log("Attempting to call getPendingStates()...");

    // First, try to get the function selector to verify it exists
    bytes4 selector = bytes4(keccak256("getPendingStates()"));
    console.log("Function selector:", uint32(selector));

    (bool pendingSuccess, bytes memory pendingData) = address(vault).staticcall(
      abi.encodeWithSignature("getPendingStates()")
    );

    console.log("Call success:", pendingSuccess);
    console.log("Return data length:", pendingData.length);

    if (!pendingSuccess && pendingData.length > 0) {
      // Try to decode the revert reason
      console.log("Revert data (hex):");
      console.logBytes(pendingData);

      // Check if it's a custom error
      if (pendingData.length >= 4) {
        bytes4 errorSelector = bytes4(pendingData);
        console.log("Error selector:", uint32(errorSelector));
      }
    }

    if (pendingSuccess && pendingData.length > 0) {
      (
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
        uint8 configType,
        int256 configValue,
        bool configPending
      ) = abi.decode(
          pendingData,
          (
            uint256,
            bool,
            uint256,
            bool,
            uint256,
            uint256,
            address,
            bool,
            uint256,
            uint256,
            bool,
            uint8,
            int256,
            bool
          )
        );
      console.log("Deposit Amount:", depositAmount);
      console.log("Deposit Pending:", depositPending);
      console.log("Withdrawal Amount:", withdrawalAmount);
      console.log("Withdrawal Pending:", withdrawalPending);
      console.log("Deploy Amount0:", deployAmount0);
      console.log("Deploy Amount1:", deployAmount1);
      console.log("Deploy Pending:", deployPending);
    } else {
      console.log("ERROR reading getPendingStates() - call failed");

      // Try to read pending storage slot directly using vm.load
      // PendingOps struct layout in storage (after BeefyVaultConcLiq variables):
      // We need to find where 'pending' is stored
      console.log("");
      console.log("=== Reading storage slots to find pending ===");
      // Check storage slots - pending should be after all BeefyVaultConcLiq storage
      // Let's check slots 0-30 to see what's there
      for (uint256 i = 0; i < 30; i++) {
        bytes32 slotValue = vm.load(address(vault), bytes32(i));
        uint256 slotUint = uint256(slotValue);
        if (slotUint != 0) {
          console.log("Storage slot", i, ":", slotUint);
          // Check if this looks like an address (last 20 bytes)
          if (i >= 10 && slotUint > type(uint96).max && slotUint < type(uint160).max * 2) {
            address possibleAddr = address(uint160(slotUint));
            console.log("  Possible address in slot", i, ":", possibleAddr);
          }
        }
      }

      // Try to call getPendingStates with trace to see exactly where it fails
      console.log("");
      console.log("=== Checking implementation contract ===");
      address impl = address(vault.getImplementation());
      console.log("Implementation address:", impl);

      // Try calling getPendingStates directly on implementation
      (bool implSuccess, bytes memory implData) = impl.staticcall(
        abi.encodeWithSignature("getPendingStates()")
      );
      console.log("Direct impl call success:", implSuccess);
      console.log("Direct impl data length:", implData.length);

      // Check if the function exists in the implementation by checking code
      console.log("");
      console.log("=== Checking implementation contract ===");
      uint256 implCodeSize;
      assembly {
        implCodeSize := extcodesize(impl)
      }
      console.log("Implementation code size:", implCodeSize);

      // Try to read the pending struct storage directly
      // Since pending is a public variable, we can try to access individual fields
      // But first, let's check if we can read other public variables
      console.log("");
      console.log("=== Testing other view functions ===");
      try vault.usdc() returns (address usdcAddr) {
        console.log("usdc() works:", usdcAddr);
      } catch {
        console.log("usdc() failed");
      }
      try vault.factory() returns (address factAddr) {
        console.log("factory() works:", factAddr);
      } catch {
        console.log("factory() failed");
      }
      try vault.controller() returns (address controllerAddr) {
        console.log("controller() works:", controllerAddr);
      } catch {
        console.log("controller() failed");
      }
      // The issue might be with the enum ConfigChangeType in the return
      // Let's try to read the pending struct fields individually if possible
      console.log("");
      console.log("=== Attempting to read pending struct via storage ===");
      // PendingOps struct layout:
      // Slot 0: depositUsdc (uint128) + withdrawUsdc (uint128) = 256 bits
      // Slot 1: swapToken0 (uint128) + swapToken1 (uint128) = 256 bits
      // Slot 2: deployAmount0 (uint128) + deployAmount1 (uint128) = 256 bits
      // Slot 3: swapRecipient (address = 160 bits) + configType (enum = 8 bits) + flags (uint8 = 8 bits) = 176 bits (padded to 256)
      // Slot 4: configValue (int256 = 256 bits)
      //
      // We need to find where 'pending' starts after BeefyVaultConcLiq storage
      // Let's check if we can find it by looking for non-zero values in later slots
      console.log("Checking storage slots 10-20 for pending struct:");
      for (uint256 i = 10; i < 21; i++) {
        bytes32 slotValue = vm.load(address(vault), bytes32(i));
        uint256 slotUint = uint256(slotValue);
        if (slotUint != 0) {
          console.log("  Slot", i, ":", slotUint);
          // Check if this could be part of the pending struct
          // First slot should have depositUsdc (upper 128 bits) and withdrawUsdc (lower 128 bits)
          uint128 upper = uint128(slotUint >> 128);
          uint128 lower = uint128(slotUint);
          if (upper > 0 || lower > 0) {
            console.log("    Upper 128 bits (depositUsdc?):", upper);
            console.log("    Lower 128 bits (withdrawUsdc?):", lower);
          }
        }
      }

      // The issue might be that the enum ConfigChangeType value in storage is invalid
      // Enums in Solidity are uint8, but if the stored value is > 3 (since enum has 4 values: None=0, PositionWidth=1, Deviation=2, TwapInterval=3)
      // it could cause issues when trying to return it

      // Let's use forge's stdStorage to find the exact slot for 'pending'
      console.log("");
      console.log("=== Using forge stdStorage to find pending slot ===");
      // We'll manually calculate: pending is a public variable, so we can use the storage slot
      // For public struct variables, Solidity uses keccak256(abi.encode(slot, struct_offset))
      // But since it's the first struct variable after controller, let's find controller's slot first

      // Try to find where usdc, factory, controller are stored
      // These are public address variables, so they should be at sequential slots
      // After BeefyVaultConcLiq storage ends

      // Let's check if the issue is with the enum - try calling a simplified version
      console.log("");
      console.log("=== Testing enum issue ===");
      // The enum ConfigChangeType has 4 values: None(0), PositionWidth(1), Deviation(2), TwapInterval(3)
      // If storage has a value > 3, it would be invalid

      // Let's try to call getPendingStates with a try-catch that shows the exact revert reason
      // But first, let's see if we can use forge's debugger or trace
      console.log("Attempting getPendingStates with detailed error capture...");

      // Use vm.expectRevert to see what error we get
      // But we can't use expectRevert in a view function, so let's try a different approach
      // Let's manually construct what getPendingStates should return and see if encoding works

      // Actually, the best way is to use forge's debug trace
      // But for now, let's check if maybe the function signature is wrong
      // or if there's a version mismatch

      console.log("Checking if this might be a storage layout issue...");
      console.log("The revert happens even with empty pending struct (all zeros)");
      console.log("This suggests the issue is with the function itself, not the data");

      // Check if getPendingStates function exists in implementation bytecode
      console.log("");
      console.log("=== Checking if getPendingStates exists in implementation ===");
      bytes4 getPendingStatesSelector = bytes4(keccak256("getPendingStates()"));
      console.log("Function selector (hex):", vm.toString(getPendingStatesSelector));

      // Get implementation bytecode
      bytes memory implCode = impl.code;
      console.log("Implementation code length:", implCode.length);

      // Search for the selector in the bytecode
      bool found = false;
      for (uint256 i = 0; i < implCode.length - 3; i++) {
        bytes4 candidate;
        assembly {
          candidate := mload(add(add(implCode, 0x20), i))
        }
        if (candidate == getPendingStatesSelector) {
          console.log("Found selector at byte offset:", i);
          found = true;
          break;
        }
      }
      console.log("Selector found in bytecode:", found);

      // The issue might be that the implementation doesn't have this function
      // or it has a different signature. Let's also check the factory's latestImplementation
      console.log("");
      console.log("=== Checking factory's latestImplementation ===");
      address factoryAddr = address(vault.factory());
      console.log("Factory address:", factoryAddr);

      // Try to get latestImplementation from factory
      (bool factorySuccess, bytes memory factoryData) = factoryAddr.staticcall(
        abi.encodeWithSignature("latestImplementation()")
      );
      if (factorySuccess && factoryData.length > 0) {
        address latestImpl = abi.decode(factoryData, (address));
        console.log("Latest implementation:", latestImpl);
        console.log("Current implementation:", impl);
        if (latestImpl != impl) {
          console.log("WARNING: Vault is NOT on latest implementation!");
          console.log("   This could cause storage layout mismatches");
          console.log("   Current:", impl);
          console.log("   Latest:", latestImpl);
        } else {
          console.log("Vault is on latest implementation");
        }
      }
    }
    console.log("");

    // 9. Check if calm
    try vault.isCalm() returns (bool isCalm) {
      console.log("=== Vault State ===");
      console.log("Is Calm:", isCalm);
    } catch Error(string memory reason) {
      console.log("ERROR checking isCalm():", reason);
    } catch (bytes memory lowLevelData) {
      console.log("ERROR checking isCalm() (low-level)");
      console.logBytes(lowLevelData);
    }
    console.log("");

    // 8. Calculate totals
    uint256 totalToken0 = vaultToken0Balance;
    uint256 totalToken1 = vaultToken1Balance;

    if (strategyAddress != address(0)) {
      totalToken0 += IERC20(token0).balanceOf(strategyAddress);
      totalToken1 += IERC20(token1).balanceOf(strategyAddress);

      // Try to get Uniswap positions for totals
      (bool success, bytes memory returnData) = strategyAddress.staticcall(
        abi.encodeWithSignature("balancesOfPool()")
      );
      if (success && returnData.length > 0) {
        (, , uint256 mainAmount0, uint256 mainAmount1, uint256 altAmount0, uint256 altAmount1) = abi
          .decode(returnData, (uint256, uint256, uint256, uint256, uint256, uint256));
        totalToken0 += mainAmount0 + altAmount0;
        totalToken1 += mainAmount1 + altAmount1;
      }
    }

    console.log("=== Summary ===");
    console.log("Total Token0:", totalToken0);
    console.log("Total Token1:", totalToken1);
    console.log("");
  }
}




