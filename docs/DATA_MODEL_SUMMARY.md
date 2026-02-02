# LP Tracking Data Model Summary

## Overview

This document summarizes the abstracted data model for tracking LP positions across multiple DEX types (Uniswap V3, Aerodrome, etc.) with comprehensive price tracking for impermanent loss calculations.

## Key Design Decisions

### 1. DEX-Agnostic Architecture

- **Generic Pool Model**: Works for any DEX type (Uniswap V3, Aerodrome, Velodrome)
- **Flexible JSON Fields**: DEX-specific data stored in JSON fields
- **Enum-Based DEX Types**: Easy to add new DEX types

### 2. Comprehensive Price Tracking

- **Token Price History**: Track all token prices over time
- **Price Snapshots**: Link prices to LP snapshots for IL calculations
- **Multiple Price Sources**: Support coingecko, uniswap, aerodrome, etc.

### 3. Impermanent Loss Tracking

- **Deposit Price Capture**: Store prices at deposit time
- **Current Price Tracking**: Link current prices to snapshots
- **IL Calculations**: Built-in IL and net return calculations
- **Hold Value**: Calculate what tokens would be worth if held

## Core Data Flow

```
Token → TokenPrice → TokenPriceSnapshot → LPSnapshot → LPPosition
                                 ↓
                         StrategySnapshot
                                 ↓
                              Strategy → Pool → DEX
```

## Data Models

### 1. **Token & Price Tracking**
- `Token`: All tokens used in any LP position
- `TokenPrice`: Historical price records per token
- `TokenPriceSnapshot`: Price pairs at specific timestamps (for IL)

### 2. **DEX & Pool Configuration**
- `DEX`: DEX type configuration (Uniswap V3, Aerodrome, etc.)
- `Pool`: Generic pool model (works for any DEX)

### 3. **Strategy & Position Tracking**
- `Strategy`: LP strategy managing positions
- `LPPosition`: User's position in a strategy
- `StrategySnapshot`: Strategy state at points in time
- `LPSnapshot`: LP position state with IL calculations

### 4. **Events & History**
- `LPDeposit`: Deposit events with price snapshots
- `LPWithdrawal`: Withdrawal events with fee collection
- `StrategyAggregate`: High-level strategy metrics

## Price Tracking for IL

### How It Works

1. **On Deposit**:
   - Capture current token prices
   - Create `TokenPriceSnapshot`
   - Link to `LPDeposit`

2. **On Snapshot**:
   - Get current token prices
   - Create new `TokenPriceSnapshot`
   - Link to `LPSnapshot`

3. **IL Calculation**:
   ```
   depositValue = amount0 * depositPrice0 + amount1 * depositPrice1
   currentValue = current position value (from strategy)
   holdValue = amount0 * currentPrice0 + amount1 * currentPrice1
   
   IL = currentValue - holdValue
   IL% = (IL / holdValue) * 100
   
   netReturn = fees - IL
   ```

## Benefits

### ✅ Universal Model
- Works for Uniswap V3, Aerodrome, and future DEXs
- Single codebase handles all DEX types

### ✅ Complete Price History
- All tokens tracked with historical prices
- Multiple price sources supported
- Price interpolation for exact timestamps

### ✅ Accurate IL Calculations
- Prices captured at deposit time
- Real-time IL tracking
- Net return calculations (fees - IL)

### ✅ Comprehensive Tracking
- Full audit trail of all events
- Historical snapshots for backtesting
- User-level position tracking

### ✅ Efficient Queries
- Proper indexes on all lookup fields
- Fast price queries with timestamps
- Optimized for reporting and analytics

## Usage Examples

### Track Prices for All Tokens

```typescript
// Automatically track prices when tokens are used
await tokenPriceService.recordTokenPrice(
  "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", // USDC
  8453, // Base
  1.0, // $1.00
  new Date(),
  "coingecko"
);
```

### Create Price Snapshot on Deposit

```typescript
// When user deposits
const priceSnapshot = await tokenPriceService.createPriceSnapshot(
  token0Address,
  token1Address,
  chainId,
  new Date()
);

await prisma.lPDeposit.create({
  data: {
    // ... deposit data
    priceSnapshotId: priceSnapshot.id,
    depositValueUSD: calculatedValue,
  },
});
```

### Calculate IL for Position

```typescript
// Calculate IL for a position
const ilData = await ilCalculationService.calculateIL(
  lpPositionId,
  currentSnapshotId
);

console.log(`IL: $${ilData.ilUSD} (${ilData.ilPercent}%)`);
console.log(`Fees: $${ilData.feesUSD}`);
console.log(`Net Return: $${ilData.netReturnUSD} (${ilData.netReturnPercent}%)`);
```

## Migration Path

1. **Phase 1**: Add new abstracted models alongside existing
2. **Phase 2**: Migrate Uniswap V3 data to new models
3. **Phase 3**: Add Aerodrome support using same models
4. **Phase 4**: Deprecate old DEX-specific models

## Next Steps

1. ✅ **Schema Creation**: Add models to `schema.prisma`
2. ⏳ **Price Service**: Implement `TokenPriceService`
3. ⏳ **IL Calculator**: Implement `ILCalculationService`
4. ⏳ **Migration Script**: Migrate existing `UniswapVault` data
5. ⏳ **Integration**: Hook into deposit/withdrawal flows
6. ⏳ **Backtesting**: Use historical prices for IL calculations

## Files

- `ABSTRACTED_LP_DATA_MODEL.md` - Full data model documentation
- `LP_TRACKING_DATA_MODEL.md` - Original Uniswap V3 model
- `TRACKING_DESIGN.md` - Tracking strategy and implementation
- `BACKTESTING_GUIDE.md` - How to use subgraph for backtesting



