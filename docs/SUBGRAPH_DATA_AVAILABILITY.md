# Uniswap V3 Subgraph Data Availability

This document outlines what data is available from the Uniswap V3 subgraph that can be used to track LP positions and calculate fees for our concentrated liquidity strategy.

## Current Usage in Server

The existing codebase (`apps/server`) uses the Uniswap V3 subgraph to fetch:
- Pool-level data (TVL, fees, token prices)
- Historical daily data (`poolDayDatas`)

**Current Query Pattern:**
```graphql
query PoolApr($poolId: ID!, $beforeDate: Int!) {
  pool(id: $poolId) {
    totalValueLockedUSD
    feeTier
    token0 { id, symbol, name, decimals }
    token1 { id, symbol, name, decimals }
    token0Price
    token1Price
  }
  poolDayDatas(first: 30, orderBy: date, orderDirection: desc, where: { pool: $poolId, date_lt: $beforeDate }) {
    date
    tvlUSD
    feesUSD
    token0Price
    token1Price
    volumeToken0
    volumeToken1
    volumeUSD
  }
}
```

## Available Entities for Position Tracking

### 1. Position Entity

Tracks individual NFT positions (via PositionManager):

```graphql
type Position {
  id: ID!                        # NFT token ID
  owner: String!                 # Position owner address
  pool: Pool!                    # Associated pool
  token0: Token!
  token1: Token!
  tickLower: Tick!               # Lower tick
  tickUpper: Tick!               # Upper tick
  liquidity: BigInt!             # Current liquidity in position
  depositedToken0: BigDecimal!   # Total token0 deposited
  depositedToken1: BigDecimal!   # Total token1 deposited
  withdrawnToken0: BigDecimal!   # Total token0 withdrawn
  withdrawnToken1: BigDecimal!   # Total token1 withdrawn
  collectedFeesToken0: BigDecimal! # Total fees collected (token0)
  collectedFeesToken1: BigDecimal! # Total fees collected (token1)
  transaction: Transaction!       # Creation transaction
  feeGrowthInside0LastX128: BigInt! # Last fee growth inside (token0)
  feeGrowthInside1LastX128: BigInt! # Last fee growth inside (token1)
  amountDepositedUSD: BigDecimal!  # USD value deposited
  amountWithdrawnUSD: BigDecimal!  # USD value withdrawn
  amountCollectedUSD: BigDecimal!  # USD value of fees collected
}
```

**Query Example:**
```graphql
query GetPosition($positionId: ID!) {
  position(id: $positionId) {
    id
    owner
    pool { id }
    token0 { id, symbol, decimals }
    token1 { id, symbol, decimals }
    tickLower { tickIdx }
    tickUpper { tickIdx }
    liquidity
    depositedToken0
    depositedToken1
    withdrawnToken0
    withdrawnToken1
    collectedFeesToken0
    collectedFeesToken1
    feeGrowthInside0LastX128
    feeGrowthInside1LastX128
    amountDepositedUSD
    amountWithdrawnUSD
    amountCollectedUSD
  }
}
```

### 2. Mint Event

Tracks when liquidity is added to a position:

```graphql
type Mint {
  id: ID!                    # Transaction hash + log index
  transaction: Transaction!
  timestamp: BigInt!
  pool: Pool!
  token0: Token!
  token1: Token!
  owner: String!
  sender: String!
  amount: BigInt!            # Amount of liquidity minted
  amount0: BigDecimal!       # Amount of token0 deposited
  amount1: BigDecimal!       # Amount of token1 deposited
  tickLower: BigInt!         # Lower tick
  tickUpper: BigInt!         # Upper tick
  logIndex: BigInt
  amountUSD: BigDecimal!     # USD value
}
```

**Query Example:**
```graphql
query GetMints($poolId: ID!, $owner: String, $first: Int!, $skip: Int!) {
  mints(
    first: $first
    skip: $skip
    orderBy: timestamp
    orderDirection: desc
    where: { 
      pool: $poolId
      owner: $owner
    }
  ) {
    id
    transaction { id, timestamp }
    timestamp
    pool { id }
    owner
    sender
    amount
    amount0
    amount1
    tickLower
    tickUpper
    amountUSD
  }
}
```

### 3. Burn Event

Tracks when liquidity is removed from a position:

```graphql
type Burn {
  id: ID!                    # Transaction hash + log index
  transaction: Transaction!
  timestamp: BigInt!
  pool: Pool!
  token0: Token!
  token1: Token!
  owner: String!
  tickLower: BigInt!
  tickUpper: BigInt!
  amount: BigInt!            # Amount of liquidity burned
  amount0: BigDecimal!       # Amount of token0 withdrawn
  amount1: BigDecimal!       # Amount of token1 withdrawn
  logIndex: BigInt
  amountUSD: BigDecimal!
}
```

**Query Example:**
```graphql
query GetBurns($poolId: ID!, $owner: String, $first: Int!, $skip: Int!) {
  burns(
    first: $first
    skip: $skip
    orderBy: timestamp
    orderDirection: desc
    where: { 
      pool: $poolId
      owner: $owner
    }
  ) {
    id
    transaction { id, timestamp }
    timestamp
    pool { id }
    owner
    amount
    amount0
    amount1
    tickLower
    tickUpper
    amountUSD
  }
}
```

### 4. Collect Event

Tracks when fees are collected from a position:

```graphql
type Collect {
  id: ID!                    # Transaction hash + log index
  transaction: Transaction!
  timestamp: BigInt!
  pool: Pool!
  owner: String!
  amount0: BigDecimal!       # Fees collected (token0)
  amount1: BigDecimal!       # Fees collected (token1)
  tickLower: BigInt!
  tickUpper: BigInt!
  logIndex: BigInt
  amountUSD: BigDecimal!     # USD value of fees collected
}
```

**Query Example:**
```graphql
query GetCollects($poolId: ID!, $owner: String, $first: Int!, $skip: Int!) {
  collects(
    first: $first
    skip: $skip
    orderBy: timestamp
    orderDirection: desc
    where: { 
      pool: $poolId
      owner: $owner
    }
  ) {
    id
    transaction { id, timestamp }
    timestamp
    pool { id }
    owner
    amount0
    amount1
    tickLower
    tickUpper
    amountUSD
  }
}
```

### 5. Pool Entity

Pool-level data (already in use):

```graphql
type Pool {
  id: ID!                    # Pool address
  token0: Token!
  token1: Token!
  fee: BigInt!               # Fee tier (e.g., 500 = 0.05%)
  tickSpacing: BigInt!
  sqrtPrice: BigInt!         # Current sqrt price
  feeGrowthGlobal0X128: BigInt!
  feeGrowthGlobal1X128: BigInt!
  token0Price: BigDecimal!
  token1Price: BigDecimal!
  liquidity: BigInt!         # Total liquidity in pool
  totalValueLockedUSD: BigDecimal!
  totalValueLockedToken0: BigDecimal!
  totalValueLockedToken1: BigDecimal!
  volumeUSD: BigDecimal!
  feesUSD: BigDecimal!
  txCount: BigInt!
  createdAtTimestamp: BigInt!
  createdAtBlockNumber: BigInt!
  # ... more fields
}
```

### 6. PositionSnapshot Entity

Historical snapshots of position state:

```graphql
type PositionSnapshot {
  id: ID!                    # position.id + timestamp
  owner: String!
  pool: Pool!
  position: Position!
  blockNumber: BigInt!
  timestamp: BigInt!
  liquidity: BigInt!
  depositedToken0: BigDecimal!
  depositedToken1: BigDecimal!
  withdrawnToken0: BigDecimal!
  withdrawnToken1: BigDecimal!
  collectedFeesToken0: BigDecimal!
  collectedFeesToken1: BigDecimal!
  transaction: Transaction!
  feeGrowthInside0LastX128: BigInt!
  feeGrowthInside1LastX128: BigInt!
}
```

**Query Example:**
```graphql
query GetPositionSnapshots($positionId: ID!, $first: Int!, $skip: Int!) {
  positionSnapshots(
    first: $first
    skip: $skip
    orderBy: timestamp
    orderDirection: desc
    where: { position: $positionId }
  ) {
    id
    timestamp
    blockNumber
    liquidity
    depositedToken0
    depositedToken1
    withdrawnToken0
    withdrawnToken1
    collectedFeesToken0
    collectedFeesToken1
    feeGrowthInside0LastX128
    feeGrowthInside1LastX128
    transaction { id }
  }
}
```

### 7. Tick Entity

Tick-level data for fee calculations:

```graphql
type Tick {
  id: ID!                    # pool.id + tick index
  pool: Pool!
  tickIdx: BigInt!           # Tick index
  liquidityGross: BigInt!
  liquidityNet: BigInt!
  price0: BigDecimal!
  price1: BigDecimal!
  feeGrowthOutside0X128: BigInt!
  feeGrowthOutside1X128: BigInt!
  # ... more fields
}
```

## Strategy-Specific Queries

### Query All Positions for Our Strategy Contract

Since our strategy manages positions directly (not via NFT), we need to query by owner:

```graphql
query GetStrategyPositions($poolId: ID!, $strategyAddress: String!, $first: Int!, $skip: Int!) {
  positions(
    first: $first
    skip: $skip
    orderBy: liquidity
    orderDirection: desc
    where: {
      pool: $poolId
      owner: $strategyAddress
    }
  ) {
    id
    owner
    tickLower { tickIdx }
    tickUpper { tickIdx }
    liquidity
    depositedToken0
    depositedToken1
    withdrawnToken0
    withdrawnToken1
    collectedFeesToken0
    collectedFeesToken1
    feeGrowthInside0LastX128
    feeGrowthInside1LastX128
    amountDepositedUSD
    amountWithdrawnUSD
    amountCollectedUSD
  }
}
```

### Query All Events for Strategy

Get all mint/burn/collect events for our strategy:

```graphql
query GetStrategyEvents(
  $poolId: ID!
  $strategyAddress: String!
  $first: Int!
  $skip: Int!
  $timestamp: BigInt!
) {
  mints(
    first: $first
    skip: $skip
    orderBy: timestamp
    orderDirection: desc
    where: {
      pool: $poolId
      owner: $strategyAddress
      timestamp_gte: $timestamp
    }
  ) {
    id
    transaction { id, timestamp, blockNumber }
    timestamp
    amount
    amount0
    amount1
    tickLower
    tickUpper
    amountUSD
  }
  
  burns(
    first: $first
    skip: $skip
    orderBy: timestamp
    orderDirection: desc
    where: {
      pool: $poolId
      owner: $strategyAddress
      timestamp_gte: $timestamp
    }
  ) {
    id
    transaction { id, timestamp, blockNumber }
    timestamp
    amount
    amount0
    amount1
    tickLower
    tickUpper
    amountUSD
  }
  
  collects(
    first: $first
    skip: $skip
    orderBy: timestamp
    orderDirection: desc
    where: {
      pool: $poolId
      owner: $strategyAddress
      timestamp_gte: $timestamp
    }
  ) {
    id
    transaction { id, timestamp, blockNumber }
    timestamp
    amount0
    amount1
    tickLower
    tickUpper
    amountUSD
  }
}
```

### Query Pool State at Specific Block

Get pool state for fee calculations:

```graphql
query GetPoolState($poolId: ID!, $blockNumber: Int!) {
  pool(id: $poolId, block: { number: $blockNumber }) {
    id
    sqrtPrice
    tick
    liquidity
    feeGrowthGlobal0X128
    feeGrowthGlobal1X128
    token0Price
    token1Price
    totalValueLockedUSD
  }
}
```

### Query Historical Fee Growth

Track fee growth over time:

```graphql
query GetPoolDayDataWithFees($poolId: ID!, $first: Int!) {
  poolDayDatas(
    first: $first
    orderBy: date
    orderDirection: desc
    where: { pool: $poolId }
  ) {
    date
    feesUSD
    feesToken0
    feesToken1
    tvlUSD
    volumeUSD
    volumeToken0
    volumeToken1
    token0Price
    token1Price
    open
    high
    low
    close
    liquidity
    sqrtPrice
    tick
  }
}
```

## Limitations and Considerations

### 1. Position Identification

**Challenge**: Our strategy contract manages positions directly via `pool.mint()`, not through the PositionManager NFT. The subgraph tracks positions by:
- NFT token ID (for PositionManager positions)
- Owner address + pool + tick range

**Solution**: Query positions by `owner = strategyAddress` and filter by tick ranges to identify main vs alt positions.

### 2. Position Key Calculation

Uniswap V3 position key = `keccak256(abi.encodePacked(owner, tickLower, tickUpper))`

The subgraph's Position entity uses NFT token ID, but we can:
- Query by owner address
- Match tick ranges to identify our positions
- Track multiple positions (main + alt)

### 3. Fee Growth Inside Calculation

The subgraph provides:
- `feeGrowthGlobal0X128` / `feeGrowthGlobal1X128` (pool-level)
- `feeGrowthInside0LastX128` / `feeGrowthInside1LastX128` (position-level)

But to calculate current fees, we need:
- Current `feeGrowthInside` for the tick range
- This requires calculating from tick-level data or querying the contract

**Best Approach**: Use subgraph for historical event tracking, but query contract directly for current fee growth values.

### 4. Real-Time vs Historical

The subgraph has indexing delay (usually a few minutes). For real-time fee calculations:
- Use subgraph for historical events and snapshots
- Query contract directly for current state
- Sync periodically

## Recommended Data Fetching Strategy

### On Strategy Deployment

1. **Fetch initial position state** from contract:
   - Main position: `(tickLower, tickUpper)`
   - Alt position: `(tickLower, tickUpper)`
   - Current liquidity in each

2. **Create position records** in database:
   - Strategy position = aggregate of main + alt
   - Track as separate "virtual" positions or aggregate

3. **Start monitoring events** from subgraph:
   - Mint events → deposits/liquidity additions
   - Burn events → withdrawals/liquidity removals
   - Collect events → fee harvesting

### Periodic Sync (Every 5-15 minutes)

1. **Fetch recent events** from subgraph:
   ```graphql
   query RecentEvents($poolId: ID!, $strategyAddress: String!, $sinceTimestamp: BigInt!) {
     mints(where: { pool: $poolId, owner: $strategyAddress, timestamp_gte: $sinceTimestamp }) { ... }
     burns(where: { pool: $poolId, owner: $strategyAddress, timestamp_gte: $sinceTimestamp }) { ... }
     collects(where: { pool: $poolId, owner: $strategyAddress, timestamp_gte: $sinceTimestamp }) { ... }
   }
   ```

2. **Fetch current contract state**:
   - Current tick ranges (may have changed on rebalance)
   - Current liquidity
   - Current fee growth values

3. **Update database**:
   - Create snapshots
   - Update LP positions
   - Calculate fees

### Fee Calculation Workflow

1. **From Subgraph** (Historical):
   - Track all mint/burn/collect events
   - Calculate net liquidity changes
   - Track collected fees

2. **From Contract** (Current):
   - Get current `feeGrowthInside0X128` / `feeGrowthInside1X128`
   - Calculate uncollected fees
   - Get current position ranges and liquidity

3. **Combine**:
   - Historical collected fees (from subgraph events)
   - Current uncollected fees (from contract)
   - Total = collected + uncollected

## Implementation Example

```typescript
import { queryTheGraph } from "@/lib/gql.js";
import { envConfig } from "@/lib/env-config.js";

const UNISWAP_V3_SUBGRAPH_ID = envConfig.get("UNISWAP_V3_SUBGRAPH_ID");

async function fetchStrategyPositions(
  poolAddress: string,
  strategyAddress: string
) {
  const query = `
    query GetStrategyPositions($poolId: ID!, $owner: String!) {
      positions(
        where: {
          pool: $poolId
          owner: $owner
        }
        orderBy: liquidity
        orderDirection: desc
      ) {
        id
        tickLower { tickIdx }
        tickUpper { tickIdx }
        liquidity
        depositedToken0
        depositedToken1
        withdrawnToken0
        withdrawnToken1
        collectedFeesToken0
        collectedFeesToken1
        feeGrowthInside0LastX128
        feeGrowthInside1LastX128
      }
    }
  `;
  
  const variables = {
    poolId: poolAddress.toLowerCase(),
    owner: strategyAddress.toLowerCase(),
  };
  
  const data = await queryTheGraph(UNISWAP_V3_SUBGRAPH_ID, query, variables);
  return data?.positions || [];
}

async function fetchStrategyEvents(
  poolAddress: string,
  strategyAddress: string,
  sinceTimestamp: bigint,
  first: number = 100
) {
  const query = `
    query GetStrategyEvents(
      $poolId: ID!
      $owner: String!
      $sinceTimestamp: BigInt!
      $first: Int!
    ) {
      mints: mints(
        first: $first
        orderBy: timestamp
        orderDirection: desc
        where: {
          pool: $poolId
          owner: $owner
          timestamp_gte: $sinceTimestamp
        }
      ) {
        id
        transaction { id, timestamp, blockNumber }
        timestamp
        amount
        amount0
        amount1
        tickLower
        tickUpper
        amountUSD
      }
      
      burns: burns(
        first: $first
        orderBy: timestamp
        orderDirection: desc
        where: {
          pool: $poolId
          owner: $owner
          timestamp_gte: $sinceTimestamp
        }
      ) {
        id
        transaction { id, timestamp, blockNumber }
        timestamp
        amount
        amount0
        amount1
        tickLower
        tickUpper
        amountUSD
      }
      
      collects: collects(
        first: $first
        orderBy: timestamp
        orderDirection: desc
        where: {
          pool: $poolId
          owner: $owner
          timestamp_gte: $sinceTimestamp
        }
      ) {
        id
        transaction { id, timestamp, blockNumber }
        timestamp
        amount0
        amount1
        tickLower
        tickUpper
        amountUSD
      }
    }
  `;
  
  const variables = {
    poolId: poolAddress.toLowerCase(),
    owner: strategyAddress.toLowerCase(),
    sinceTimestamp: sinceTimestamp.toString(),
    first,
  };
  
  const data = await queryTheGraph(UNISWAP_V3_SUBGRAPH_ID, query, variables);
  return {
    mints: data?.mints || [],
    burns: data?.burns || [],
    collects: data?.collects || [],
  };
}
```

## Data Mapping to Our Model

| Subgraph Field | Our Model Field | Notes |
|---------------|-----------------|-------|
| `position.liquidity` | `StrategyPositionSnapshot.totalLiquidity` | Sum of main + alt |
| `position.collectedFeesToken0` | Historical collected fees | From events |
| `mint.amount0` / `mint.amount1` | `LPDeposit.amount0` / `amount1` | When user deposits |
| `burn.amount0` / `burn.amount1` | `LPWithdrawal.amount0` / `amount1` | When user withdraws |
| `collect.amount0` / `collect.amount1` | Fee collection events | Harvest operations |
| `position.feeGrowthInside0LastX128` | `StrategyPositionSnapshot.feeGrowthInsideMain0X128` | Need contract for current |
| Pool `feeGrowthGlobal0X128` | Current fee growth | For calculations |

## Summary

**What's Available:**
- ✅ Position-level data (liquidity, fees collected, deposits/withdrawals)
- ✅ Event history (mint, burn, collect)
- ✅ Pool-level metrics (TVL, fees, volume)
- ✅ Historical snapshots (position snapshots, pool day data)

**What's Missing/Needs Contract:**
- ⚠️ Current fee growth inside (need contract query for real-time)
- ⚠️ Current tick ranges after rebalancing
- ⚠️ Current uncollected fees (need contract)

**Recommendation:**
- Use subgraph for historical event tracking and snapshots
- Query contract directly for current state (fee growth, tick ranges)
- Combine both sources for complete fee calculation




