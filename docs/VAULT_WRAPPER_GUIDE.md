# Vault Wrapper Implementation Guide

## Overview

The Vault Wrapper system provides a per-user contract that safely manages deposits to Beefy Concentrated Liquidity vaults, handling the complexity of:
- Token swaps via 1inch (controller-driven)
- Waiting for vault "calm" state before depositing
- Allowing user cancellation at any stage
- Managing withdrawals with automatic swap back to USDC

## Architecture

### Contracts

1. **VaultWrapper.sol** - Per-user wrapper instance
2. **VaultWrapperFactory.sol** - Factory for deploying wrappers using CREATE2

### Key Design Decisions

- **One wrapper per user**: Each user gets their own wrapper contract for isolated state
- **Controller-driven**: Server/controller provides 1inch swap calldata and triggers vault deposits
- **Calm-aware**: Automatically blocks vault deposits when pool is volatile
- **Cancellable**: Users can exit and get USDC back before vault deposit

## User Flow

### Deposit Flow

```
1. User → depositUSDC(amount)
   └─ USDC transferred to wrapper

2. Controller → executeSwaps([swapCalls])
   └─ Swaps USDC to pool tokens via 1inch

3. Controller checks if vault.isCalm()
   ├─ If calm: depositToVault()
   │  └─ Deposits pool tokens, receives vault shares
   └─ If not calm: wait and retry later
```

### Withdrawal Flow

```
1. User → withdraw(vault, shares, [swapCalls])
   ├─ Withdraws shares from vault (receives pool tokens)
   ├─ Executes swaps to convert back to USDC
   └─ Transfers USDC to user
```

### Cancellation Flow

```
1. User → cancelDeposit([swapCalls])
   ├─ If in USDC state: return USDC directly
   ├─ If in pool tokens: swap back to USDC first
   └─ Transfer USDC to user
```

## Contract Addresses

### Base Mainnet

- **USDC**: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`
- **1inch Router**: `0x111111125421cA6dc452d289314280a0f8842A65`
- **Vault (Example)**: `0xd505Ce5D357F117C5Cb4E8A21c2656Bb2c60AcB2`

## Deployment

### 1. Deploy Factory

```solidity
VaultWrapperFactory factory = new VaultWrapperFactory(
    USDC_ADDRESS,
    CONTROLLER_ADDRESS
);
```

### 2. Create Wrapper for User

```solidity
address wrapperAddress = factory.createWrapper(userAddress);
```

Wrapper address is deterministic (CREATE2) and can be predicted:

```solidity
address predicted = factory.predictWrapperAddress(userAddress);
```

## Usage Examples

### For Users (Direct Contract Calls)

#### Deposit USDC

```solidity
// Approve USDC to wrapper
IERC20(USDC).approve(wrapperAddress, amount);

// Deposit
VaultWrapper(wrapperAddress).depositUSDC(amount);
```

#### Cancel Deposit

```solidity
// Cancel with no swaps (if still in USDC)
VaultWrapper.SwapCall[] memory swaps = new VaultWrapper.SwapCall[](0);
VaultWrapper(wrapperAddress).cancelDeposit(swaps);
```

#### Withdraw

```solidity
// Withdraw with swaps back to USDC (provided by controller)
VaultWrapper(wrapperAddress).withdraw(vaultAddress, shares, swapCalls);
```

### For Controller (Server)

#### Execute Swaps

```solidity
// Get swap calldata from 1inch API
bytes memory swapData = getFromOneInchAPI(...);

// Create swap call
VaultWrapper.SwapCall[] memory swaps = new VaultWrapper.SwapCall[](1);
swaps[0] = VaultWrapper.SwapCall({
    target: ONEINCH_ROUTER,
    data: swapData,
    value: 0
});

// Execute as controller
VaultWrapper(wrapperAddress).executeSwaps(swaps);
```

#### Deposit to Vault

```solidity
// Check if vault is calm first
bool isCalm = VaultWrapper(wrapperAddress).isVaultCalm(vaultAddress);

if (isCalm) {
    // Calculate amounts and minShares
    VaultWrapper(wrapperAddress).depositToVault(
        vaultAddress,
        amount0,
        amount1,
        minShares
    );
}
```

## Testing

### Run All Tests

```bash
# Basic deployment tests
forge test --match-contract VaultWrapperDeploymentTest -vv

# Deposit flow tests
forge test --match-contract VaultWrapperDepositTest -vv

# Withdrawal flow tests
forge test --match-contract VaultWrapperWithdrawTest -vv

# Cancellation tests
forge test --match-contract VaultWrapperCancelTest -vv

# Not-calm vault tests (real-world scenarios)
forge test --match-contract VaultWrapperNotCalmForkTest -vv
```

### Fork Testing

All tests use Base mainnet fork to test against real vaults:

```bash
export BASE_HTTP_RPC_URL="https://mainnet.base.org"
forge test --match-contract VaultWrapper -vv --fork-url $BASE_HTTP_RPC_URL
```

## State Machine

```
┌─────────┐
│  Empty  │
└────┬────┘
     │ depositUSDC()
     ▼
┌─────────────┐
│ USDC Held   │◄───── cancelDeposit() → User gets USDC back
└─────┬───────┘
      │ executeSwaps()
      ▼
┌──────────────────┐
│ Pool Tokens Held │◄── cancelDeposit(swaps) → Swap → User gets USDC
└────────┬─────────┘
         │ depositToVault() [only if calm]
         ▼
┌──────────────────┐
│  Vault Shares    │
└────────┬─────────┘
         │ withdraw(swaps)
         ▼
┌──────────────────┐
│ User gets USDC   │
└──────────────────┘
```

## Security Features

### Access Control

- **onlyOwner**: User can deposit USDC, withdraw, and cancel
- **onlyController**: Controller can execute swaps and deposit to vault
- **onlyFactory**: Factory can initialize and update controller

### Safety Checks

- **VaultNotCalm**: Prevents deposits when pool is volatile
- **InvalidTarget**: Only allows swaps via approved 1inch router
- **InsufficientBalance**: Prevents operations without required tokens
- **ReentrancyGuard**: Protects all state-changing functions

### Token Safety

- Uses OpenZeppelin's `SafeERC20` for all token transfers
- Approvals reset to 0 before setting new allowance
- All token transfers checked for success

## Integration with Server

### 1. Check if User Has Wrapper

```typescript
const wrapperAddress = await factory.getWrapper(userAddress);
if (wrapperAddress === ethers.ZeroAddress) {
    // Create wrapper
    await factory.createWrapper(userAddress);
}
```

### 2. Prepare Deposit

Instead of directly calling vault, prepare calls for wrapper:

```typescript
// Old way: Direct vault deposit
const calls = [
    approveCall,
    swapCall,
    vaultDepositCall
];

// New way: Via wrapper
const calls = [
    { to: usdc, data: approve(wrapper, amount) },         // User approves to wrapper
    { to: wrapper, data: depositUSDC(amount) },           // User deposits to wrapper
    { to: wrapper, data: executeSwaps(swaps) },           // Controller swaps
    // depositToVault called separately when calm
];
```

### 3. Monitor Calm State

```typescript
async function monitorAndDepositWhenCalm(wrapperAddress, vaultAddress) {
    const wrapper = new ethers.Contract(wrapperAddress, WRAPPER_ABI);
    
    while (true) {
        const isCalm = await wrapper.isVaultCalm(vaultAddress);
        
        if (isCalm) {
            // Execute deposit
            await wrapper.depositToVault(vault, amount0, amount1, minShares);
            break;
        }
        
        // Wait 30 seconds and retry
        await sleep(30000);
    }
}
```

### 4. Handle Withdrawals

```typescript
async function prepareWithdrawal(wrapper, vault, shares) {
    // Get 1inch swap calldata for pool tokens → USDC
    const swaps = await getSwapCallsFromOneInch(...);
    
    // User calls withdraw
    return wrapper.withdraw(vault, shares, swaps);
}
```

## Calm State Behavior

### What is "Calm"?

A vault is "calm" when the pool price is stable:

```
|currentTick - twapTick| <= maxTickDeviation
```

- **currentTick**: Current pool price tick
- **twapTick**: Time-weighted average price tick
- **maxTickDeviation**: Maximum allowed deviation

### Why It Matters

Beefy vaults reject configuration changes and deposits during volatile periods to prevent:
- Dangerous updates during price manipulation
- Unfavorable deposit ratios
- MEV exploitation

### Handling Not-Calm Vaults

The wrapper design allows:

1. **User deposits anytime** - USDC held safely in wrapper
2. **Swaps execute anytime** - Pool tokens prepared in advance
3. **Vault deposit waits** - Controller retries when calm
4. **User can cancel** - Get USDC back if vault stays volatile

See `VaultWrapperNotCalmFork.t.sol` for comprehensive tests of not-calm scenarios.

## Gas Estimates

Based on fork tests:

- **Create wrapper**: ~1,200,000 gas
- **Deposit USDC**: ~179,000 gas
- **Execute swaps**: Variable (depends on 1inch)
- **Deposit to vault**: Variable (depends on vault)
- **Withdraw**: Variable (depends on swaps)
- **Cancel**: ~120,000 gas

## Next Steps

### Server Integration

1. Update `BeefyConcLiqVaultHandler` to use wrapper
2. Add wrapper factory address to config
3. Modify `prepareDeposit()` to generate wrapper calls
4. Add calm state monitoring service
5. Implement retry logic for deposits

### Monitoring Service

Create a keeper/cron service that:
- Monitors wrappers with pending deposits
- Checks vault calm status
- Triggers `depositToVault()` when calm
- Alerts users if vault stays volatile too long

### User Interface

Add UI elements for:
- Wrapper status display
- Calm state indicator
- Cancel button (if deposit pending)
- Estimated time until calm (based on historical data)

## Troubleshooting

### Deposit Fails with "VaultNotCalm"

**Cause**: Pool is volatile (high price deviation)

**Solution**: 
- Wait for pool to stabilize
- Check calm status: `wrapper.isVaultCalm(vault)`
- User can cancel deposit and retry later

### Swap Fails with "InvalidTarget"

**Cause**: Attempting to call non-1inch router

**Solution**: Ensure all swap calls target `0x111111125421cA6dc452d289314280a0f8842A65`

### Cannot Create Duplicate Wrapper

**Cause**: User already has a wrapper

**Solution**: Check existing wrapper: `factory.getWrapper(user)`

## Resources

- **Contracts**: `/apps/contracts2/src/VaultWrapper*.sol`
- **Tests**: `/apps/contracts2/test/VaultWrapper*.t.sol`
- **1inch API**: https://portal.1inch.dev/
- **Beefy Docs**: https://docs.beefy.finance/







