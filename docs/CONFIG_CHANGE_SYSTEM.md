# Config Change Queuing System

## Overview

The config change queuing system allows strategy configuration updates (like `setPositionWidth`, `setDeviation`, `setTwapInterval`) to be queued and executed when the vault is calm, mitigating `isCalm()` issues.

## Problem

Strategy configuration functions require the pool to be calm (`isCalm()` must return `true`). However, during volatile market conditions, the pool may not be calm for extended periods, preventing critical configuration updates.

## Solution

The AnalogVault now includes a config change queuing system that works similarly to the deposit flow:

1. **User queues config change** - The vault owner calls a queue function (doesn't require `isCalm()`)
2. **Controller monitors** - The backend controller monitors for pending config changes
3. **Controller executes when calm** - When `isCalm()` returns true, the controller calls `executeConfigChange()`
4. **Change applied** - The queued config change is applied to the strategy

## Architecture

### Contract Functions

#### Queue Functions (Owner Only)

```solidity
function queuePositionWidthChange(int24 _width) external onlyVaultOwner
function queueDeviationChange(int56 _maxDeviation) external onlyVaultOwner
function queueTwapIntervalChange(uint32 _interval) external onlyVaultOwner
```

These functions allow the vault owner to queue configuration changes without requiring the vault to be calm.

#### Execute Function (Controller Only)

```solidity
function executeConfigChange() external onlyController nonReentrant
```

This function:
- Checks if a config change is pending
- Verifies the vault is calm (`isCalm()`)
- Applies the config change to the strategy
- Clears the pending state

#### Cancel Function (Owner Only)

```solidity
function cancelConfigChange() external onlyVaultOwner
```

Allows the owner to cancel a pending config change if they change their mind.

#### View Function

```solidity
function getPendingConfigChange() external view returns (
    ConfigChangeType changeType,
    int256 value,
    bool isPending
)
```

Returns details about any pending config change.

## Data Structures

### ConfigChangeType Enum

```solidity
enum ConfigChangeType {
    None,
    PositionWidth,
    Deviation,
    TwapInterval
}
```

### PendingConfigChange Struct

```solidity
struct PendingConfigChange {
    ConfigChangeType changeType;
    int256 value;        // Can hold int24, int56, or uint32 cast to int256
    bool isPending;
}
```

## Events

```solidity
event ConfigChangeQueued(ConfigChangeType indexed changeType, int256 value);
event ConfigChangeExecuted(ConfigChangeType indexed changeType, int256 value);
event ConfigChangeCancelled(ConfigChangeType indexed changeType);
```

## Usage Flow

### 1. Queue a Config Change (Frontend/Owner)

```typescript
// Example: Queue position width change
const tx = await analogVault.queuePositionWidthChange(50);
await tx.wait();

console.log('Config change queued, waiting for calm conditions...');
```

### 2. Monitor for Pending Changes (Backend/Controller)

```typescript
// Backend controller monitors for pending changes
const pendingChange = await analogVault.getPendingConfigChange();

if (pendingChange.isPending) {
  // Check if vault is calm
  const isCalm = await analogVault.isCalm();

  if (isCalm) {
    // Execute the pending change
    const tx = await analogVault.connect(controller).executeConfigChange();
    await tx.wait();

    console.log('Config change executed successfully');
  } else {
    console.log('Waiting for calm conditions...');
  }
}
```

### 3. Cancel a Change (Optional)

```typescript
// Owner can cancel if needed
const tx = await analogVault.cancelConfigChange();
await tx.wait();

console.log('Config change cancelled');
```

## Error Handling

### Common Errors

- `ConfigChangeAlreadyPending()` - Cannot queue multiple changes at once
- `NoConfigChangePending()` - No change to execute or cancel
- `VaultNotCalm()` - Cannot execute while vault is not calm
- `OnlyVaultOwner()` - Only owner can queue/cancel
- `OnlyController()` - Only controller can execute

## Security Considerations

1. **Access Control**
   - Only vault owner can queue and cancel changes
   - Only controller can execute changes
   - Owner is verified via `owner()` from Ownable

2. **State Management**
   - Only one pending change allowed at a time
   - Pending state is cleared after execution
   - Reentrancy protection on execute function

3. **Calm Verification**
   - `executeConfigChange()` requires `isCalm()` to be true
   - Same pattern as `depositToVault()` for consistency

## Integration with Existing Systems

### Deposit Flow Comparison

| Aspect | Deposit Flow | Config Change Flow |
|--------|-------------|-------------------|
| Initiation | User calls `deposit()` | Owner calls `queue*Change()` |
| Execution | Controller calls `depositToVault()` | Controller calls `executeConfigChange()` |
| Calm Check | Required at execution | Required at execution |
| Cancellation | `cancelDeposit()` | `cancelConfigChange()` |

### Backend Controller Updates

The backend controller should be updated to:

1. Monitor for pending config changes
2. Check `isCalm()` periodically
3. Execute pending changes when calm
4. Handle execution errors gracefully
5. Notify user of execution status

## Benefits

1. **No Stuck Configurations** - Changes can be queued even during volatile periods
2. **Safe Execution** - Changes only applied when vault is calm
3. **User Transparency** - Clear events and state tracking
4. **Consistent Pattern** - Mirrors existing deposit flow
5. **Flexible Cancellation** - Owner can cancel if needed

## Future Enhancements

Potential improvements:

1. **Multiple Queued Changes** - Queue multiple changes to be applied together
2. **Time-based Execution** - Auto-execute after specific time
3. **Priority System** - Prioritize certain config changes
4. **Batch Execution** - Execute multiple vaults' changes in one transaction

## Testing

See test files:
- `test/AnalogVaultConfigChanges.t.sol` - Unit tests for config change functions
- `test/AnalogVaultConfigChangesFork.t.sol` - Fork tests with real contracts

## Related Documentation

- [STRATEGY_USAGE.md](STRATEGY_USAGE.md) - Strategy configuration details
- [STRATEGY_UPDATE_CALM_ERROR.md](STRATEGY_UPDATE_CALM_ERROR.md) - Original isCalm issue documentation
- [VAULT_WRAPPER_GUIDE.md](VAULT_WRAPPER_GUIDE.md) - General vault wrapper documentation
