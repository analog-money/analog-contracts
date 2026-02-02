# Actual Fee Values for StrategyPassiveManagerUniswap

## Contract Address
**0x58e8fc1f0981d98ba2c52c8ea0f96782e43f84d8** on Base

## How to Check on Basescan

### Method 1: Read Contract Tab (Recommended)

1. Go to: https://basescan.org/address/0x58e8fc1f0981d98ba2c52c8ea0f96782e43f84d8#readContract

2. Try these functions in order:
   - `getAllFees()` - If available, returns all fee info directly
   - `getStratFeeId()` - Returns the fee configuration ID
   - `depositFee()` - Should return 0 (always 0 per contract)
   - `withdrawFee()` - Should return 0 (always 0 per contract)

3. If `getAllFees()` doesn't work, follow this path:
   - Call `factory()` to get factory address
   - On the factory contract, call `beefyFeeConfig()` to get fee config address
   - On the fee config contract, call `getFees(0x58e8fc1f0981d98ba2c52c8ea0f96782e43f84d8)` with strategy address

### Method 2: Check Recent Transactions

Look at recent `harvest()` transactions and check the `ChargedFees` event logs:
- Event: `ChargedFees(uint256 callFeeAmount, uint256 beefyFeeAmount, uint256 strategistFeeAmount)`
- This shows the actual fee amounts in the most recent harvest

## Fee Calculation Formula

From the contract code:

```solidity
// Line 412 & 426: Fee calculation during harvest
amountToSwap0 = _amount0 * fees.total / DIVISOR;  // DIVISOR = 1e18
amountToSwap1 = _amount1 * fees.total / DIVISOR;
```

**Percentage Formula:**
```
fee_percentage = (fees.total / 1e18) * 100
```

### Example Values:
- If `fees.total = 450000000000000000` (0.45 × 1e18) → **4.5%**
- If `fees.total = 45000000000000000` (0.045 × 1e18) → **4.5%**  
- If `fees.total = 0` → **0%** (Zero fees)

## What Fees Are Charged On

✅ **YES - Charged on:**
- Yield/fees earned from Uniswap positions
- Collected during `harvest()` calls

❌ **NO - NOT charged on:**
- Deposits (always 0%)
- Withdrawals (always 0%)
- Principal amount

## Fee Distribution

Once fees are collected (converted to native token):
- **Call Fee**: Goes to the person who calls `harvest()`
- **Strategist Fee**: Goes to the strategist address
- **Beefy Fee**: Goes to Beefy treasury (remaining after call + strategist)

## Next Steps

Please check the Basescan page and report back:
1. What is the `fees.total` value? (in wei/raw format)
2. What is the calculated percentage?
3. What are the individual fee breakdowns (beefy, call, strategist)?

This will allow us to calculate exactly how much yield is taken from users.


