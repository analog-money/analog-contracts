# AnalogVault Contract Size Optimization Suggestions

## Current Status
- **Size**: 25.17 KB (25,777 bytes)
- **Limit**: 24 KB (24,576 bytes)
- **Over by**: 1,201 bytes (4.9%)

## Recommended Optimizations

### 1. Move Swap Execution Logic to Library (HIGH IMPACT - ~800-1000 bytes)

**Current**: `_executeSwaps()` and `_approveToken()` are internal functions in the contract.

**Move to**: `libraries/SwapExecutor.sol`

```solidity
library SwapExecutor {
    address public constant ONEINCH_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;
    
    struct SwapCall {
        address target;
        bytes data;
        uint256 value;
    }
    
    function executeSwaps(SwapCall[] calldata swapCalls) internal {
        uint256 swapCount = swapCalls.length;
        for (uint256 i = 0; i < swapCount; i++) {
            SwapCall calldata swap = swapCalls[i];
            if (swap.target != ONEINCH_ROUTER) revert InvalidTarget();
            (bool success, ) = swap.target.call{value: swap.value}(swap.data);
            if (!success) revert SwapFailed();
        }
    }
    
    function approveToken(IERC20 token, uint256 amount) internal {
        if (amount > 0) {
            token.safeApprove(ONEINCH_ROUTER, 0);
            token.safeApprove(ONEINCH_ROUTER, amount);
        }
    }
}
```

**Benefits**:
- Removes ~50-60 lines from main contract
- Reusable across contracts
- Reduces bytecode size by ~800-1000 bytes

---

### 2. Move Config Change Execution to Library (MEDIUM IMPACT - ~400-600 bytes)

**Current**: `executeConfigChange()` contains switch logic for different config types.

**Move to**: `libraries/ConfigChangeExecutor.sol`

```solidity
library ConfigChangeExecutor {
    enum ConfigChangeType {
        None,
        PositionWidth,
        Deviation,
        TwapInterval
    }
    
    struct PendingConfigChange {
        ConfigChangeType changeType;
        int256 value;
        bool isPending;
    }
    
    function executeConfigChange(
        IStrategyConfig strategy,
        PendingConfigChange memory change
    ) internal {
        if (change.changeType == ConfigChangeType.PositionWidth) {
            strategy.setPositionWidth(int24(change.value));
        } else if (change.changeType == ConfigChangeType.Deviation) {
            strategy.setDeviation(int56(change.value));
        } else if (change.changeType == ConfigChangeType.TwapInterval) {
            strategy.setTwapInterval(uint32(uint256(change.value)));
        }
    }
}
```

**Benefits**:
- Removes ~20-30 lines from main contract
- Cleaner separation of concerns
- Reduces bytecode size by ~400-600 bytes

---

### 3. Move View Functions to Separate Interface/Helper (LOW-MEDIUM IMPACT - ~300-500 bytes)

**Current**: Multiple view functions that just return struct fields.

**Options**:
- **Option A**: Keep them but make them more compact (already done)
- **Option B**: Move to a separate view-only contract (not recommended - adds complexity)
- **Option C**: Combine multiple view functions into one that returns all pending states

**Recommended**: Option C - Create a single function that returns all pending states:

```solidity
function getPendingStates() external view returns (
    uint256 depositAmount,
    bool depositPending,
    uint256 withdrawalAmount,
    bool withdrawalPending,
    uint256 swapToken0,
    uint256 swapToken1,
    address swapRecipient,
    bool swapPending,
    ConfigChangeType configType,
    int256 configValue,
    bool configPending
) {
    return (
        pendingDeposit.usdcAmount,
        pendingDeposit.isPending,
        pendingWithdrawal.usdcAmount,
        pendingWithdrawal.isPending,
        pendingSwap.token0Amount,
        pendingSwap.token1Amount,
        pendingSwap.recipient,
        pendingSwap.isPending,
        pendingConfigChange.changeType,
        pendingConfigChange.value,
        pendingConfigChange.isPending
    );
}
```

**Benefits**:
- Reduces from 4 view functions to 1
- Saves ~300-500 bytes
- Still maintains backward compatibility if needed

---

### 4. Move Deposit Logic to Library (MEDIUM IMPACT - ~600-800 bytes)

**Current**: `_depositToVaultInternal()` contains complex deposit calculation logic.

**Move to**: `libraries/DepositExecutor.sol`

```solidity
library DepositExecutor {
    function executeDeposit(
        IStrategyConcLiq strategy,
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        function() external view returns (uint256, uint256) balances,
        function() external view returns (uint256) price,
        function() external view returns (uint256) swapFee
    ) internal {
        // Check vault is calm
        if (!strategy.isCalm()) revert VaultNotCalm();
        
        // Remove liquidity
        strategy.beforeAction();
        
        // Calculate required tokens
        (uint256 _bal0, uint256 _bal1) = balances();
        uint256 _price = price();
        // ... rest of logic
    }
}
```

**Note**: This is more complex because it needs access to contract state. Consider keeping this in the contract but simplifying it.

**Benefits**:
- If feasible, saves ~600-800 bytes
- Better code organization

---

### 5. Inline Small Functions (LOW IMPACT - ~100-200 bytes)

**Current**: Some functions are just wrappers.

**Examples**:
- `getVaultBalances()` just calls `balances()` - can be removed
- `getTokenBalance()` is a simple wrapper - can be inlined where used

**Benefits**:
- Small savings (~100-200 bytes)
- Simpler code

---

### 6. Remove Redundant View Functions (LOW IMPACT - ~200-300 bytes)

**Current**: Some view functions duplicate functionality.

**Remove**:
- `getVaultBalances()` - users can call `balances()` directly
- `getTokenBalance()` - users can call `IERC20(token).balanceOf()` directly
- `getAvailableTokens()` - can be computed off-chain

**Benefits**:
- Saves ~200-300 bytes
- Reduces contract complexity

---

## Implementation Priority

### Phase 1: Quick Wins (Target: ~1,200 bytes saved)
1. ✅ Move swap execution to library (~800-1000 bytes)
2. ✅ Remove redundant view functions (~200-300 bytes)

**Total Expected Savings**: ~1,000-1,300 bytes
**Result**: Contract should be under 24KB limit

### Phase 2: Further Optimization (if needed)
3. Move config change execution to library (~400-600 bytes)
4. Combine view functions (~300-500 bytes)
5. Inline small functions (~100-200 bytes)

---

## Example Implementation: SwapExecutor Library

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

library SwapExecutor {
    using SafeERC20 for IERC20;
    
    address public constant ONEINCH_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;
    
    error InvalidTarget();
    error SwapFailed();
    
    struct SwapCall {
        address target;
        bytes data;
        uint256 value;
    }
    
    function execute(SwapCall[] calldata swapCalls) internal {
        uint256 swapCount = swapCalls.length;
        for (uint256 i = 0; i < swapCount; i++) {
            SwapCall calldata swap = swapCalls[i];
            if (swap.target != ONEINCH_ROUTER) revert InvalidTarget();
            (bool success, ) = swap.target.call{value: swap.value}(swap.data);
            if (!success) revert SwapFailed();
        }
    }
    
    function approve(IERC20 token, uint256 amount) internal {
        if (amount > 0) {
            token.safeApprove(ONEINCH_ROUTER, 0);
            token.safeApprove(ONEINCH_ROUTER, amount);
        }
    }
}
```

**Usage in AnalogVault**:
```solidity
import {SwapExecutor} from "./libraries/SwapExecutor.sol";

contract AnalogVault {
    using SwapExecutor for SwapExecutor.SwapCall[];
    
    // Remove SwapCall struct from contract
    // Remove _executeSwaps and _approveToken functions
    
    function swapAndDeploy(SwapExecutor.SwapCall[] calldata swapCalls, ...) {
        if (swapCalls.length > 0) {
            SwapExecutor.execute(swapCalls);
        }
        // ...
    }
    
    function executeSwap(SwapExecutor.SwapCall[] calldata swapCalls) {
        SwapExecutor.approve(token0, amount0);
        SwapExecutor.approve(token1, amount1);
        SwapExecutor.execute(swapCalls);
        // ...
    }
}
```

---

## Estimated Total Savings

| Optimization | Bytes Saved | Priority |
|-------------|-------------|----------|
| Swap execution library | 800-1000 | HIGH |
| Remove redundant views | 200-300 | HIGH |
| Config change library | 400-600 | MEDIUM |
| Combine view functions | 300-500 | MEDIUM |
| Inline small functions | 100-200 | LOW |
| **TOTAL** | **1,800-2,600** | |

**Expected Result**: Contract size should be **22.5-23.4 KB** (well under 24KB limit)

---

## Notes

1. **Library Deployment**: Libraries are deployed separately and linked, so they don't count toward contract size limit.

2. **Gas Costs**: Moving to libraries may slightly increase gas costs due to external calls, but the savings in contract size are worth it.

3. **Testing**: All existing tests should continue to work with minimal changes (mainly import updates).

4. **Backward Compatibility**: Consider keeping old view functions as deprecated if they're used by frontend/backend, or update all callers.



