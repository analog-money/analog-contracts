# StrategyPassiveManagerUniswap Usage Guide

## Overview

`StrategyPassiveManagerUniswap` is a Beefy Finance contract for managing concentrated liquidity positions on Uniswap V3. This guide explains how to configure it to charge users **zero fees** while performing **free rebalancing** operations.

## Contract Architecture

The strategy manages two liquidity positions:
1. **Main Position**: A 50/50 balanced position around the current price
2. **Alternative Position**: A single-sided limit order position for the token with excess value

Both positions are automatically adjusted based on the `positionWidth` setting and current pool conditions.

## Zero Fees Configuration

### Fee Structure

Fees are charged during the `harvest()` function via the `_chargeFees()` method. Fees are fetched from an external `IFeeConfig` contract using `getFees()`.

The fee structure includes:
- **Total Fee**: `fees.total` - Percentage of earned fees charged
- **Call Fee**: `fees.call` - Percentage to harvester
- **Strategist Fee**: `fees.strategist` - Percentage to strategist
- **Beefy Fee**: `fees.beefy` - Percentage to Beefy (remaining after call + strategist)

All fees use `DIVISOR = 1 ether` (1e18), so `fees.total = 0` means 0% fees.

### Setting Zero Fees

To charge users zero fees, you must:

1. **Create a zero-fee configuration** in the `IFeeConfig` contract:
   ```solidity
   FeeCategory({
       total: 0,           // 0% total fees
       call: 0,            // 0% call fee
       strategist: 0,      // 0% strategist fee
       beefy: 0,           // 0% beefy fee
       label: "Zero Fees",
       active: true
   })
   ```

2. **Set the fee ID** on your strategy:
   ```solidity
   strategy.setStratFeeId(zeroFeeConfigId);
   ```

3. **Verify zero fees**:
   ```solidity
   (uint256 total, uint256 call, uint256 strategist, uint256 beefy) = strategy.getAllFees();
   // All should return 0
   ```

**Note**: Deposit and withdraw fees are already hardcoded to 0 in the contract (lines 170-180 of `StratFeeManagerInitializable.sol`).

### Fee Charging Flow

During harvest:
1. Fees are claimed from Uniswap positions (`_claimEarnings()`)
2. Liquidity is removed (`_removeLiquidity()`)
3. Fees are charged (`_chargeFees()`):
   - If `fees.total = 0`, no tokens are swapped or transferred
   - All earned fees remain in the strategy and benefit users
4. Liquidity is re-added with remaining tokens (`_addLiquidity()`)

## Free Rebalancing

### Rebalancing Function

The `moveTicks()` function (line 359) allows rebalancing positions:
- Claims earnings from current positions
- Removes liquidity
- Recalculates tick positions based on current price
- Adds liquidity back to new positions

### Access Control

Rebalancing requires the `onlyRebalancers` modifier, which checks:
```solidity
modifier onlyRebalancers() {
    if (!IStrategyFactory(factory).rebalancers(msg.sender)) revert NotAuthorized();
    _;
}
```

### Setting Up Free Rebalancing

1. **Register as rebalancer** in the `IStrategyFactory`:
   - Call `factory.setRebalancer(yourAddress, true)`
   - This must be done by the factory owner

2. **Call rebalancing** (free for registered rebalancers):
   ```solidity
   strategy.moveTicks();
   ```

3. **Gas costs**: You pay for gas, but no protocol fees are charged for rebalancing

**Important**: The rebalancing function still requires the `onlyCalmPeriods` modifier, meaning the current price must be within the allowed deviation from TWAP.

## Configurable Settings

### 1. Position Width (`setPositionWidth`)

**Function**: `setPositionWidth(int24 _width)`

**Description**: Controls the width of liquidity positions. Higher values = wider range = less frequent rebalancing needed but lower capital efficiency.

**Default**: Set during initialization

**Calculation**: 
- Main position range = `currentTick ± (width * tickSpacing)`
- Alt position range varies based on imbalance

**Example**:
```solidity
// Narrow position (higher capital efficiency, more rebalancing)
strategy.setPositionWidth(10);

// Wide position (lower capital efficiency, less rebalancing)
strategy.setPositionWidth(50);
```

**Recommendation**: Start with 20-30 for balanced efficiency vs. rebalancing frequency.

### 2. Max Tick Deviation (`setDeviation`)

**Function**: `setDeviation(int56 _maxDeviation)`

**Description**: Maximum allowed deviation from TWAP for deposits/harvests/rebalancing. Prevents operations during volatile periods.

**Constraints**: Must be < `tickSpacing * 4`

**Default**: Not set during initialization (must be set manually)

**Example**:
```solidity
// Allow 100 ticks deviation from TWAP
int24 tickSpacing = pool.tickSpacing();
strategy.setDeviation(tickSpacing * 3); // 75% of max allowed
```

**Recommendation**: Set to `tickSpacing * 2` to 3 for reasonable volatility protection.

### 3. TWAP Interval (`setTwapInterval`)

**Function**: `setTwapInterval(uint32 _interval)`

**Description**: Time window for calculating TWAP (Time-Weighted Average Price) used in volatility checks.

**Constraints**: Must be >= 60 seconds

**Default**: 120 seconds (set during initialization, line 176)

**Example**:
```solidity
// Use 5-minute TWAP for more stability
strategy.setTwapInterval(300);

// Use 2-minute TWAP for more responsiveness
strategy.setTwapInterval(120);
```

**Recommendation**: Keep at 120 seconds for most cases.

### 4. Fee Configuration (`setStratFeeId`)

**Function**: `setStratFeeId(uint256 _feeId)`

**Description**: Sets which fee configuration to use from the `IFeeConfig` contract.

**Access**: `onlyManager` (owner or keeper)

**For Zero Fees**: Set to a fee config ID with all fees = 0

**Example**:
```solidity
// Set to zero-fee configuration
strategy.setStratFeeId(0); // Assuming ID 0 is zero fees
```

### 5. Swap Paths (`setLpToken0ToNativePath`, `setLpToken1ToNativePath`)

**Functions**: 
- `setLpToken0ToNativePath(bytes calldata _path)`
- `setLpToken1ToNativePath(bytes calldata _path)`

**Description**: Uniswap V3 encoded paths for swapping fee tokens to native token (ETH/ETH equivalent).

**Usage**: Only relevant if fees > 0. With zero fees, these can remain empty.

**Format**: `token0_address (20 bytes) + fee (3 bytes) + token1_address (20 bytes) + ...`

**Example**:
```solidity
// USDC -> WETH path with 0.05% fee
bytes memory path = abi.encodePacked(
    usdcAddress,
    uint24(500), // 0.05% = 500
    wethAddress
);
strategy.setLpToken0ToNativePath(path);
```

### 6. Unirouter (`setUnirouter`)

**Function**: `setUnirouter(address _unirouter)`

**Description**: Address of the router/swapper contract for fee token swaps.

**Usage**: Only relevant if fees > 0. With zero fees, not critical.

**Access**: `onlyOwner`

## Operational Workflow

### Initialization

```solidity
// 1. Deploy strategy
StrategyPassiveManagerUniswap strategy = new StrategyPassiveManagerUniswap();

// 2. Initialize
CommonAddresses memory common = CommonAddresses({
    vault: vaultAddress,
    unirouter: unirouterAddress,
    strategist: strategistAddress,
    factory: factoryAddress
});

strategy.initialize(
    poolAddress,
    quoterAddress,
    positionWidth, // e.g., 25
    lpToken0ToNativePath, // empty bytes if zero fees
    lpToken1ToNativePath, // empty bytes if zero fees
    common
);

// 3. Configure zero fees
strategy.setStratFeeId(zeroFeeConfigId);

// 4. Set deviation (if needed)
int24 tickSpacing = IUniswapV3Pool(poolAddress).tickSpacing();
strategy.setDeviation(tickSpacing * 2);
```

### Daily Operations

1. **Harvesting** (claim fees, rebalance):
   ```solidity
   strategy.harvest(); // Uses tx.origin as call fee recipient (will be 0 with zero fees)
   ```

2. **Manual Rebalancing** (if needed):
   ```solidity
   // Must be registered as rebalancer first
   strategy.moveTicks();
   ```

3. **Emergency Operations**:
   ```solidity
   // Pause in emergency
   strategy.panic(0, 0);
   
   // Unpause
   strategy.unpause();
   ```

## Key Functions for Zero-Fee Operation

### User-Facing (via Vault)
- `deposit()` - Called by vault, adds liquidity
- `withdraw()` - Called by vault, removes liquidity
- `beforeAction()` - Called before deposit/withdraw to claim fees and remove liquidity

### Admin/Owner
- `harvest()` - Claim fees and rebalance (with zero fees, just rebalances)
- `moveTicks()` - Manual rebalancing (requires rebalancer role)
- `setPositionWidth()` - Adjust position width
- `setDeviation()` - Adjust volatility tolerance
- `setTwapInterval()` - Adjust TWAP calculation window
- `setStratFeeId()` - Change fee configuration

### View Functions
- `balances()` - Current token balances (accounting for fees)
- `balancesOfThis()` - Tokens in strategy contract
- `balancesOfPool()` - Tokens in Uniswap positions
- `isCalm()` - Check if price is within allowed deviation
- `price()` - Current pool price
- `range()` - Current position price range
- `getAllFees()` - View current fee configuration

## Fee Distribution (With Zero Fees)

When `fees.total = 0`:
1. All Uniswap fees earned remain in the strategy
2. No tokens are swapped to native
3. All earnings benefit users proportionally
4. Fees accumulate in `fees0` and `fees1` until harvest
5. On harvest, fees are re-added as liquidity (no deductions)

## Important Considerations

### Calm Period Requirement

Most operations require `onlyCalmPeriods`:
- Current price must be within `maxTickDeviation` of TWAP
- Prevents operations during high volatility
- If price moves too far, operations revert with `NotCalm()`

### Position Adjustment

Positions are automatically adjusted on:
- First deposit (`initTicks` set to true)
- After each harvest
- Manual `moveTicks()` call

Positions are NOT adjusted on regular deposits/withdraws (only on first deposit).

### Locked Profit

Harvested fees are "locked" for 1 hour (DURATION) and linearly released:
- Prevents instant withdrawal of newly harvested fees
- Smooths returns for users
- With zero fees, this mechanism still applies to Uniswap fees earned

### Gas Costs

- **Harvest**: ~200k-300k gas (varies with position size)
- **Rebalancing**: Same as harvest (~200k-300k gas)
- **Deposit/Withdraw**: ~150k-200k gas
- You pay gas costs, but no protocol fees

## Recommended Configuration for Zero Fees

```solidity
// Position width: Balanced
positionWidth = 25; // Adjust based on pool volatility

// Deviation: Moderate protection
maxTickDeviation = tickSpacing * 2; // Allow 2x tick spacing deviation

// TWAP: Standard
twapInterval = 120; // 2 minutes

// Fees: Zero
feeConfigId = 0; // Zero-fee configuration

// Rebalancer: Your address registered in factory
rebalancerAddress = yourAddress;
```

## Monitoring

Key metrics to monitor:
1. **Position utilization**: How much of position range is currently active
2. **Fee accumulation**: Rate of `fees0` and `fees1` growth
3. **Rebalancing frequency**: How often `moveTicks()` needs to be called
4. **Calm period violations**: How often operations fail due to `NotCalm()`
5. **Price deviation**: Distance from TWAP

## Security Notes

1. **Access Control**:
   - Owner: Can change most settings
   - Manager: Owner or keeper (set in factory)
   - Rebalancer: Must be registered in factory
   - Vault: Can call deposit/withdraw/beforeAction

2. **Emergency Controls**:
   - `panic()`: Removes liquidity and pauses
   - `unpause()`: Resumes operations
   - `retireVault()`: Shuts down strategy (only if totalSupply = 1000)

3. **Reentrancy Protection**:
   - `minting` flag prevents reentrancy in Uniswap callbacks
   - Uses OpenZeppelin's SafeERC20

## Summary

To achieve **zero fees** and **free rebalancing**:

1. ✅ Set fee config ID to one with `total = 0`
2. ✅ Register your address as rebalancer in factory
3. ✅ Configure position width, deviation, and TWAP appropriately
4. ✅ Monitor and rebalance as needed using `moveTicks()`
5. ✅ Harvest regularly to compound Uniswap fees back into positions

All Uniswap fees earned will benefit users proportionally, and you can rebalance for free (just gas costs).




