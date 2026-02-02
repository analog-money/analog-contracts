# Two-Step Withdrawal Process

## Overview

The withdrawal process has been split into two separate transactions to handle the challenge of unknown token amounts when generating 1inch swap calldata.

## Problem

Previously, the withdrawal was done in a single transaction that:
1. Withdrew tokens from strategy
2. Swapped them to USDC using 1inch
3. Sent USDC to user

The issue: **1inch swap calldata requires exact input amounts**, but we don't know exact amounts until after the on-chain withdrawal executes.

## Solution

Split into two steps that execute sequentially:

### Step 1: `withdrawFromStrategy()`
- **Purpose**: Redeem tokens from strategy to vault
- **Parameters**:
  - `amount0`: Amount of token0 to withdraw (0 = all)
  - `amount1`: Amount of token1 to withdraw (0 = all)
  - `minAmount0`: Minimum token0 expected (slippage protection)
  - `minAmount1`: Minimum token1 expected (slippage protection)
- **Actions**:
  1. Calls `strategy.beforeAction()` to remove liquidity
  2. Withdraws specified amounts from strategy to vault
  3. Checks slippage protection
  4. Records actual withdrawn amounts in `pendingWithdrawAmount0` and `pendingWithdrawAmount1`
  5. Re-deposits remaining tokens back to strategy
- **Emits**: `WithdrawnFromStrategy(amount0, amount1)`

### Step 2: `swapAndSendToUser()`
- **Purpose**: Swap withdrawn tokens and send USDC to recipient
- **Parameters**:
  - `swapCalls`: Array of 1inch swap calls
  - `recipient`: Address to receive USDC
- **Actions**:
  1. Verifies pending withdrawal amounts exist
  2. Approves tokens to 1inch router
  3. Executes swaps using pending amounts
  4. Transfers received USDC to recipient
  5. Clears pending amounts
- **Emits**: `SwappedAndSent(usdcAmount, recipient)`

## Accounting

Contract maintains state variables to track withdrawn tokens:
- `pendingWithdrawAmount0`: Token0 amount waiting to be swapped
- `pendingWithdrawAmount1`: Token1 amount waiting to be swapped

These are:
- Set in step 1 (`withdrawFromStrategy`)
- Used in step 2 (`swapAndSendToUser`)
- Cleared after step 2 completes

## Server Flow

The server orchestrates the two-step process:

1. **Prepare Step 1**: Generate `withdrawFromStrategy` transaction
2. **Execute Step 1**: User signs and executes transaction
3. **Wait for Confirmation**: Transaction completes on-chain
4. **Read Actual Amounts**: Query `pendingWithdrawAmount0` and `pendingWithdrawAmount1`
5. **Fetch Fresh Quotes**: Call 1inch API with exact amounts
6. **Prepare Step 2**: Generate `swapAndSendToUser` transaction with fresh swap calldata
7. **Execute Step 2**: User signs and executes transaction

## Contract Changes

### New Functions

```solidity
function withdrawFromStrategy(
    uint256 amount0,
    uint256 amount1,
    uint256 minAmount0,
    uint256 minAmount1
) external onlyVaultOwner nonReentrant

function swapAndSendToUser(
    SwapCall[] calldata swapCalls,
    address recipient
) external onlyVaultOwner nonReentrant
```

### New State Variables

```solidity
uint256 public pendingWithdrawAmount0;
uint256 public pendingWithdrawAmount1;
```

### New Events

```solidity
event WithdrawnFromStrategy(uint256 amount0, uint256 amount1);
event SwappedAndSent(uint256 usdcAmount, address recipient);
```

## Handler Changes

`AnalogVaultWithdrawHandler` now prepares **two transaction calls**:

```typescript
// Call 1: Withdraw from strategy
{
  to: vaultAddress,
  data: withdrawFromStrategyData,
  type: "beefy-withdraw-analog-vault",
  protocolMetadata: { action: "Withdraw from Strategy" }
}

// Call 2: Swap and send to user
{
  to: vaultAddress,
  data: swapAndSendToUserData,
  type: "beefy-withdraw-analog-vault",
  protocolMetadata: { action: "Swap and Send" }
}
```

## Security Considerations

1. **Only Owner**: Both functions can only be called by vault owner
2. **Reentrancy Protection**: Both functions have `nonReentrant` modifier
3. **Slippage Protection**: Step 1 validates minimum amounts received
4. **Accounting Safety**: Step 2 requires pending amounts to exist
5. **Router Validation**: All swaps must target approved 1inch router

## Testing

Comprehensive fork tests in `AnalogVaultTwoStepWithdrawFork.t.sol`:

- ✅ Step 1 successfully withdraws tokens
- ✅ Step 2 successfully swaps and sends USDC
- ✅ Complete two-step process end-to-end
- ✅ Step 2 reverts if called without step 1
- ✅ Slippage protection works correctly
- ✅ Only owner can call both functions
- ✅ Pending amounts are correctly tracked

## Benefits

1. **Accurate Swaps**: 1inch receives exact amounts, optimal routing
2. **No Dust**: All withdrawn tokens are swapped (no leftover amounts)
3. **Better UX**: Server can show exact amounts between steps
4. **Flexibility**: Steps can be executed at different times if needed
5. **Transparency**: Clear accounting with on-chain state variables

## Original Function

The original `withdraw()` function remains available for backwards compatibility, but new integrations should use the two-step approach for better accuracy.






