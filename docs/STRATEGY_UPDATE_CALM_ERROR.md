# Strategy Config Update Failing: NotCalm() Error

## Problem Summary

When trying to update strategy configuration using the `/config/update` endpoint, the transactions revert with a `NotCalm()` error.

## Root Cause

The Beefy strategy contract has a built-in safety mechanism that prevents configuration changes when the pool is **not calm** (experiencing volatility). This is a security feature to prevent dangerous updates during market instability.

### What is "Calm"?

A pool is considered "calm" when:
```
|currentTick - twapTick| <= maxTickDeviation
```

Where:
- `currentTick`: Current pool price tick
- `twapTick`: Time-Weighted Average Price tick over the configured `twapInterval`
- `maxTickDeviation`: Maximum allowed deviation before updates are blocked

## Why This Happens

The strategy checks if the pool is calm before allowing ANY of these configuration updates:
- `setPositionWidth()`
- `setDeviation()`
- `setTwapInterval()`
- `setRebalanceInterval()` (if exists)

During volatile market conditions:
- Price moves quickly
- Current tick deviates significantly from TWAP
- `NotCalm()` check fails
- Transaction reverts

## Solutions

### Option 1: Wait for Market Stability (Recommended)

**When to use:** Most common solution for production environments

1. Monitor the pool until it stabilizes
2. Retry the update during calm market conditions
3. Typically happens during low-volatility periods

**Checking if pool is calm:**
```bash
# Run the check test with your strategy address
cd apps/contracts2
forge test --match-test test_check_calm --fork-url https://mainnet.base.org -vvv
```

### Option 2: Increase maxTickDeviation

**When to use:** If you need to make updates but pool is consistently volatile

**Problem:** This creates a chicken-and-egg situation:
- You need to call `setDeviation()` to increase `maxTickDeviation`
- But `setDeviation()` itself requires the pool to be calm
- So you must wait for a calm moment to increase the threshold

**Steps:**
1. Wait for a brief calm period (even a few seconds can work)
2. Immediately call `setDeviation()` with a higher value
3. Once increased, subsequent updates will have more tolerance

**Example values:**
```javascript
// Conservative (current default)
maxTickDeviation = 200  // Very tight - requires stable pool

// Moderate
maxTickDeviation = 500  // Allows more volatility

// Aggressive (use with caution)
maxTickDeviation = 1000 // Allows significant volatility
```

⚠️ **Warning:** Higher deviation values reduce safety guarantees. Only increase if you understand the risks.

### Option 3: Automated Retry Logic

**When to use:** For automated systems that can retry periodically

Implement retry logic in your application:

```typescript
async function updateStrategyConfigWithRetry(
  strategyId: string,
  config: ConfigUpdate,
  maxRetries = 10,
  delayMs = 30000 // 30 seconds
) {
  for (let attempt = 0; attempt < maxRetries; attempt++) {
    try {
      const result = await updateStrategyConfig(strategyId, config);
      console.log("✅ Update successful");
      return result;
    } catch (error) {
      if (error.message?.includes("NotCalm")) {
        console.log(`⏳ Pool not calm (attempt ${attempt + 1}/${maxRetries}). Retrying in ${delayMs/1000}s...`);
        await new Promise(resolve => setTimeout(resolve, delayMs));
      } else {
        throw error; // Different error, don't retry
      }
    }
  }
  throw new Error("Failed to update strategy: Pool remained volatile");
}
```

### Option 4: Emergency Override (Advanced)

**When to use:** Only in emergency situations with proper access control

If you control the strategy contract and need emergency updates:

1. Deploy a modified contract version that allows owner to bypass calm check for emergency updates
2. Upgrade via beacon (if using upgradeable pattern)
3. Make necessary updates
4. Revert to original contract

⚠️ **Not recommended** for normal operations. Introduces security risks.

## Bugs Fixed

### Bug 1: Wrong Contract Address (FIXED ✅)

**Previous behavior:**
- Server was sending update calls to `deployment.contractAddress`
- For Beefy strategies, this is the **vault address**
- Setter functions exist on the **strategy contract**, not the vault
- All calls would fail even if pool was calm

**Fix applied:**
```typescript
// Now correctly uses strategyAddress for Beefy strategies
const contractAddress = isBeefyUniswap && deploymentConfig?.strategyAddress 
    ? deploymentConfig.strategyAddress 
    : deployment.contractAddress;
```

### Bug 2: Missing Deployment Check (FIXED ✅)

**Previous behavior:**
- Endpoint checked `strategy.contractAddress` field
- This field was removed in database migration
- Always returned "Strategy is not deployed" error

**Fix applied:**
```typescript
// Now correctly queries StrategyDeployment table
const deployment = await req.prisma.strategyDeployment.findUnique({
    where: { 
        strategyId_userId: {
            strategyId: id,
            userId: userId,
        }
    },
});
```

## Testing

### Test 1: Check if your deployment is calm

```bash
cd apps/contracts2

# Edit test/CheckStrategyCalm.t.sol and set STRATEGY_ADDRESS
# Then run:
forge test --match-test test_check_calm --fork-url https://mainnet.base.org -vvv
```

### Test 2: Simulate update attempt

The fork test `StrategyConfigUpdateFork.t.sol` demonstrates the `NotCalm()` error:

```bash
forge test --match-test test_update_positionWidth_as_owner -vvv --fork-url https://mainnet.base.org
```

## Monitoring

To monitor pool calmness in your application:

```typescript
async function isPoolCalm(strategyAddress: string): Promise<{
  isCalm: boolean;
  currentDeviation: number;
  maxAllowed: number;
}> {
  const strategy = new ethers.Contract(strategyAddress, STRATEGY_ABI, provider);
  const pool = new ethers.Contract(await strategy.pool(), POOL_ABI, provider);
  
  // Get current tick
  const slot0 = await pool.slot0();
  const currentTick = slot0.tick;
  
  // Get TWAP
  const twapInterval = await strategy.twapInterval();
  const observe = await pool.observe([twapInterval, 0]);
  const twapTick = (observe.tickCumulatives[1] - observe.tickCumulatives[0]) / twapInterval;
  
  // Check deviation
  const deviation = Math.abs(currentTick - twapTick);
  const maxDeviation = await strategy.maxTickDeviation();
  
  return {
    isCalm: deviation <= maxDeviation,
    currentDeviation: deviation,
    maxAllowed: maxDeviation,
  };
}
```

## Recommendations

1. **For Production:**
   - Implement retry logic with exponential backoff
   - Monitor pool volatility before attempting updates
   - Alert users when updates fail due to volatility
   - Provide UI feedback showing calm status

2. **For Development:**
   - Use the `CheckStrategyCalm.t.sol` test to verify pool state
   - Test updates during known calm periods
   - Consider increasing `maxTickDeviation` for testnet deployments

3. **For Emergency Updates:**
   - Document emergency procedures
   - Have backup plans for volatile markets
   - Consider time-locked updates that execute during next calm period

## Related Files

- **Server Fix:** `apps/server2/src/routes/strategies/routes.ts` (lines 897-920)
- **Fork Tests:** `apps/contracts2/test/StrategyConfigUpdateFork.t.sol`
- **Calm Check:** `apps/contracts2/test/CheckStrategyCalm.t.sol`
- **Contract Docs:** `apps/contracts2/docs/STRATEGY_USAGE.md`

## Summary

The `NotCalm()` error is **not a bug** - it's a security feature. Your updates are being rejected because the pool is volatile. The correct solution is to wait for market stability or implement retry logic, not to bypass the safety check.

The actual bugs (wrong contract address and missing deployment check) have been fixed in the server code.







