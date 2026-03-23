# Uniswap V3 Subgraph Queries for Strategy Tracking

## Configuration

The server uses `UNISWAP_V3_SUBGRAPH_ID` from environment variables. The subgraph is accessed via:
```
https://gateway.thegraph.com/api/{GRAPH_API_KEY}/subgraphs/id/{UNISWAP_V3_SUBGRAPH_ID}
```

## Available Queries for Our Strategy

### 1. Get Strategy Positions

Query all positions owned by our strategy contract:

```graphql
query GetStrategyPositions($poolId: ID!, $strategyAddress: String!) {
  positions(
    where: {
      pool: $poolId
      owner: $strategyAddress
    }
    orderBy: liquidity
    orderDirection: desc
  ) {
    id
    owner
    pool {
      id
      token0 { id, symbol, decimals }
      token1 { id, symbol, decimals }
      feeTier
    }
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
    transaction {
      id
      blockNumber
      timestamp
    }
  }
}
```

**Usage**: Identify main vs alt positions by matching tick ranges.

### 2. Get Recent Events (Mint/Burn/Collect)

Track liquidity changes and fee collections:

```graphql
query GetStrategyEvents(
  $poolId: ID!
  $strategyAddress: String!
  $sinceTimestamp: BigInt!
  $first: Int!
) {
  mints(
    first: $first
    orderBy: timestamp
    orderDirection: desc
    where: {
      pool: $poolId
      owner: $strategyAddress
      timestamp_gte: $sinceTimestamp
    }
  ) {
    id
    transaction {
      id
      blockNumber
      timestamp
    }
    timestamp
    owner
    sender
    amount
    amount0
    amount1
    tickLower
    tickUpper
    amountUSD
  }
  
  burns(
    first: $first
    orderBy: timestamp
    orderDirection: desc
    where: {
      pool: $poolId
      owner: $strategyAddress
      timestamp_gte: $sinceTimestamp
    }
  ) {
    id
    transaction {
      id
      blockNumber
      timestamp
    }
    timestamp
    owner
    amount
    amount0
    amount1
    tickLower
    tickUpper
    amountUSD
  }
  
  collects(
    first: $first
    orderBy: timestamp
    orderDirection: desc
    where: {
      pool: $poolId
      owner: $strategyAddress
      timestamp_gte: $sinceTimestamp
    }
  ) {
    id
    transaction {
      id
      blockNumber
      timestamp
    }
    timestamp
    owner
    amount0
    amount1
    tickLower
    tickUpper
    amountUSD
  }
}
```

**Usage**: 
- Mint events = liquidity added (deposits/rebalances)
- Burn events = liquidity removed (withdrawals/rebalances)
- Collect events = fees harvested

### 3. Get Position Snapshots

Historical position state snapshots:

```graphql
query GetPositionSnapshots(
  $positionId: ID!
  $first: Int!
  $skip: Int!
) {
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
    transaction {
      id
      blockNumber
      timestamp
    }
  }
}
```

**Usage**: Track position changes over time, especially useful after rebalances.

### 4. Get Pool State

Current pool state for fee calculations:

```graphql
query GetPoolState($poolId: ID!) {
  pool(id: $poolId) {
    id
    token0 {
      id
      symbol
      name
      decimals
    }
    token1 {
      id
      symbol
      name
      decimals
    }
    feeTier
    tickSpacing
    sqrtPrice
    tick
    liquidity
    feeGrowthGlobal0X128
    feeGrowthGlobal1X128
    token0Price
    token1Price
    totalValueLockedUSD
    totalValueLockedToken0
    totalValueLockedToken1
    volumeUSD
    feesUSD
    txCount
    createdAtTimestamp
    createdAtBlockNumber
  }
}
```

**Usage**: Get current pool metrics and fee growth values.

### 5. Get Historical Pool Data

Daily aggregations for APR calculations:

```graphql
query GetPoolDayData(
  $poolId: ID!
  $first: Int!
  $sinceDate: Int
) {
  poolDayDatas(
    first: $first
    orderBy: date
    orderDirection: desc
    where: {
      pool: $poolId
      date_gte: $sinceDate
    }
  ) {
    date
    tvlUSD
    feesUSD
    feesToken0
    feesToken1
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

**Usage**: Calculate historical APR and performance metrics.

### 6. Get Swaps for Position

Track swaps that generated fees for our positions:

```graphql
query GetPoolSwaps(
  $poolId: ID!
  $first: Int!
  $sinceTimestamp: BigInt!
) {
  swaps(
    first: $first
    orderBy: timestamp
    orderDirection: desc
    where: {
      pool: $poolId
      timestamp_gte: $sinceTimestamp
    }
  ) {
    id
    transaction {
      id
      blockNumber
      timestamp
    }
    timestamp
    amount0
    amount1
    amountUSD
    sqrtPriceX96
    tick
  }
}
```

**Usage**: Analyze trading activity and fee generation.

## Data We Can Extract

### From Positions Query
- ✅ Current liquidity in each position (main + alt)
- ✅ Total deposited/withdrawn tokens
- ✅ Total collected fees
- ✅ Last recorded fee growth values
- ✅ Tick ranges (to identify main vs alt)

### From Events (Mint/Burn/Collect)
- ✅ Deposit history (mint events)
- ✅ Withdrawal history (burn events)
- ✅ Fee collection history (collect events)
- ✅ Transaction hashes and block numbers
- ✅ Timestamps for all operations

### From Position Snapshots
- ✅ Historical position state
- ✅ Liquidity changes over time
- ✅ Fee growth tracking
- ✅ Before/after snapshots on rebalances

### From Pool State
- ✅ Current price and tick
- ✅ Global fee growth
- ✅ Pool TVL and metrics

### From Pool Day Data
- ✅ Historical APR calculations
- ✅ Fee trends
- ✅ Volume patterns

## What We Still Need from Contract

Since subgraph has indexing delay and doesn't track everything:

### Must Query Contract Directly:
1. **Current fee growth inside** (for real-time fee calculation)
2. **Current tick ranges** (after recent rebalances)
3. **Current uncollected fees** (from `positions()` function)
4. **Current liquidity** (most up-to-date value)

## Implementation Strategy

### Initial Setup
```typescript
// 1. Fetch positions from subgraph
const subgraphPositions = await fetchStrategyPositions(poolAddress, strategyAddress);

// 2. Query contract for current state
const contractPositions = await fetchContractPositions(strategyAddress);

// 3. Match positions (by tick ranges) and merge data
const mergedPositions = mergePositionData(subgraphPositions, contractPositions);

// 4. Store in database
await storeStrategySnapshot(strategyId, mergedPositions);
```

### Periodic Sync
```typescript
// 1. Get last sync timestamp
const lastSync = await getLastSyncTimestamp(strategyId);

// 2. Fetch new events from subgraph
const events = await fetchStrategyEvents(
  poolAddress, 
  strategyAddress, 
  lastSync,
  100 // first
);

// 3. Process events
for (const mint of events.mints) {
  await processMintEvent(mint);
}

for (const burn of events.burns) {
  await processBurnEvent(burn);
}

for (const collect of events.collects) {
  await processCollectEvent(collect);
}

// 4. Fetch current contract state
const currentState = await fetchContractState(strategyAddress);

// 5. Update database
await updateStrategyState(strategyId, currentState);

// 6. Calculate fees for all LPs
await calculateFeesForAllLPs(strategyId);
```

## Example Integration Code

```typescript
import { queryTheGraph } from "@/lib/gql.js";
import { envConfig } from "@/lib/env-config.js";
import { baseClient } from "@/lib/rpc.js";
import { getContract } from "viem";

const UNISWAP_V3_SUBGRAPH_ID = envConfig.get("UNISWAP_V3_SUBGRAPH_ID");

// Strategy contract ABI (simplified)
const STRATEGY_ABI = [
  "function pool() view returns (address)",
  "function positionMain() view returns (int24 tickLower, int24 tickUpper)",
  "function positionAlt() view returns (int24 tickLower, int24 tickUpper)",
  "function balances() view returns (uint256 token0Bal, uint256 token1Bal)",
] as const;

async function syncStrategyFromSubgraph(strategyId: string, strategyAddress: string) {
  // 1. Get strategy contract info
  const strategyContract = getContract({
    address: strategyAddress as `0x${string}`,
    abi: STRATEGY_ABI,
    client: baseClient,
  });
  
  const poolAddress = (await strategyContract.read.pool()) as string;
  const [mainPos, altPos] = await Promise.all([
    strategyContract.read.positionMain(),
    strategyContract.read.positionAlt(),
  ]);
  
  // 2. Query subgraph for positions
  const query = `
    query GetStrategyPositions($poolId: ID!, $owner: String!) {
      positions(
        where: {
          pool: $poolId
          owner: $owner
        }
      ) {
        id
        tickLower { tickIdx }
        tickUpper { tickIdx }
        liquidity
        collectedFeesToken0
        collectedFeesToken1
        feeGrowthInside0LastX128
        feeGrowthInside1LastX128
      }
    }
  `;
  
  const data = await queryTheGraph(
    UNISWAP_V3_SUBGRAPH_ID,
    query,
    {
      poolId: poolAddress.toLowerCase(),
      owner: strategyAddress.toLowerCase(),
    }
  );
  
  // 3. Match positions by tick ranges
  const mainPosition = data.positions.find((p: any) => 
    p.tickLower.tickIdx === mainPos[0] && p.tickUpper.tickIdx === mainPos[1]
  );
  
  const altPosition = data.positions.find((p: any) =>
    p.tickLower.tickIdx === altPos[0] && p.tickUpper.tickIdx === altPos[1]
  );
  
  // 4. Aggregate data
  const totalLiquidity = (
    BigInt(mainPosition?.liquidity || 0) + 
    BigInt(altPosition?.liquidity || 0)
  ).toString();
  
  const totalCollectedFees0 = (
    parseFloat(mainPosition?.collectedFeesToken0 || 0) +
    parseFloat(altPosition?.collectedFeesToken0 || 0)
  ).toString();
  
  const totalCollectedFees1 = (
    parseFloat(mainPosition?.collectedFeesToken1 || 0) +
    parseFloat(altPosition?.collectedFeesToken1 || 0)
  ).toString();
  
  // 5. Store in database
  await prisma.strategyPositionSnapshot.create({
    data: {
      strategyId,
      poolAddress,
      tickLowerMain: mainPos[0],
      tickUpperMain: mainPos[1],
      tickLowerAlt: altPos[0],
      tickUpperAlt: altPos[1],
      liquidityMain: mainPosition?.liquidity || "0",
      liquidityAlt: altPosition?.liquidity || "0",
      totalLiquidity,
      // ... other fields
    },
  });
  
  return {
    mainPosition,
    altPosition,
    totalLiquidity,
    totalCollectedFees0,
    totalCollectedFees1,
  };
}
```

## Summary

The Uniswap V3 subgraph provides:
- ✅ Historical event tracking (mint, burn, collect)
- ✅ Position-level data (liquidity, fees collected)
- ✅ Pool-level metrics (TVL, fees, volume)
- ✅ Position snapshots for historical tracking

**Combine with contract queries for:**
- ⚠️ Real-time fee growth values
- ⚠️ Current position state (after rebalances)
- ⚠️ Uncollected fees calculation

This hybrid approach gives us complete tracking while minimizing contract queries.




