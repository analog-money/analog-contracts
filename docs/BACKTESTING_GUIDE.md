# Backtesting Fee Performance with Subgraph

This guide shows how to calculate historical fees earned by your strategy using only the Uniswap V3 subgraph.

## Key Insight

**You don't need live data or RPC queries for backtesting!**

The subgraph provides all historical events:
- `Collect` events = fees collected (what you actually earned)
- `Mint` events = liquidity added
- `Burn` events = liquidity removed

## Query Strategy Events

### Step 1: Get All Fee Collections

```graphql
query GetStrategyFeeCollections(
  $poolId: ID!
  $strategyAddress: String!
  $first: Int = 1000
) {
  collects(
    first: $first
    orderBy: timestamp
    orderDirection: asc
    where: {
      pool: $poolId
      owner: $strategyAddress
    }
  ) {
    id
    transaction {
      id
      timestamp
      blockNumber
    }
    timestamp
    amount0      # Fees in token0
    amount1      # Fees in token1
    amountUSD    # Total fees in USD
    tickLower
    tickUpper
    pool {
      id
      token0 { symbol, decimals }
      token1 { symbol, decimals }
    }
  }
}
```

**Result**: List of all fee collections with amounts and timestamps.

### Step 2: Get All Liquidity Changes

```graphql
query GetStrategyLiquidityChanges(
  $poolId: ID!
  $strategyAddress: String!
  $first: Int = 1000
) {
  mints(
    first: $first
    orderBy: timestamp
    orderDirection: asc
    where: {
      pool: $poolId
      owner: $strategyAddress
    }
  ) {
    id
    transaction {
      id
      timestamp
      blockNumber
    }
    timestamp
    amount      # Liquidity added
    amount0     # Token0 added
    amount1     # Token1 added
    amountUSD
    tickLower
    tickUpper
  }
  
  burns(
    first: $first
    orderBy: timestamp
    orderDirection: asc
    where: {
      pool: $poolId
      owner: $strategyAddress
    }
  ) {
    id
    transaction {
      id
      timestamp
      blockNumber
    }
    timestamp
    amount      # Liquidity removed
    amount0     # Token0 removed
    amount1     # Token1 removed
    amountUSD
    tickLower
    tickUpper
  }
}
```

**Result**: All deposits (mints) and withdrawals (burns) over time.

## Calculate Total Fees Earned

```typescript
interface CollectEvent {
  timestamp: string;
  amountUSD: string;
  amount0: string;
  amount1: string;
}

function calculateTotalFees(collects: CollectEvent[]) {
  const totalFeesUSD = collects.reduce(
    (sum, collect) => sum + parseFloat(collect.amountUSD),
    0
  );
  
  const totalFeesToken0 = collects.reduce(
    (sum, collect) => sum + parseFloat(collect.amount0),
    0
  );
  
  const totalFeesToken1 = collects.reduce(
    (sum, collect) => sum + parseFloat(collect.amount1),
    0
  );
  
  return {
    totalFeesUSD,
    totalFeesToken0,
    totalFeesToken1,
    collectionCount: collects.length,
  };
}
```

## Calculate Fees Over Time

```typescript
function calculateFeesOverTime(collects: CollectEvent[]) {
  // Sort by timestamp
  const sorted = [...collects].sort(
    (a, b) => parseInt(a.timestamp) - parseInt(b.timestamp)
  );
  
  let cumulativeFees = 0;
  const feesOverTime = sorted.map((collect) => {
    cumulativeFees += parseFloat(collect.amountUSD);
    return {
      timestamp: new Date(parseInt(collect.timestamp) * 1000),
      feesUSD: parseFloat(collect.amountUSD),
      cumulativeFeesUSD: cumulativeFees,
    };
  });
  
  return feesOverTime;
}
```

## Track LP Shares Over Time

```typescript
interface MintEvent {
  timestamp: string;
  amount: string;  // Liquidity amount
  amountUSD: string;
}

interface BurnEvent {
  timestamp: string;
  amount: string;  // Liquidity amount
  amountUSD: string;
}

function calculateLPSharesOverTime(
  mints: MintEvent[],
  burns: BurnEvent[]
) {
  // Combine and sort all events
  const allEvents = [
    ...mints.map(m => ({ ...m, type: 'mint' as const })),
    ...burns.map(b => ({ ...b, type: 'burn' as const })),
  ].sort((a, b) => parseInt(a.timestamp) - parseInt(b.timestamp));
  
  let totalLiquidity = 0;
  const sharesOverTime = allEvents.map((event) => {
    if (event.type === 'mint') {
      totalLiquidity += parseFloat(event.amount);
    } else {
      totalLiquidity -= parseFloat(event.amount);
    }
    
    return {
      timestamp: new Date(parseInt(event.timestamp) * 1000),
      type: event.type,
      liquidityChange: parseFloat(event.amount) * (event.type === 'mint' ? 1 : -1),
      totalLiquidity,
    };
  });
  
  return sharesOverTime;
}
```

## Calculate Fees Per LP Share

```typescript
function calculateFeesPerShare(
  collects: CollectEvent[],
  mints: MintEvent[],
  burns: BurnEvent[]
) {
  // Get LP shares at each collection time
  const sharesOverTime = calculateLPSharesOverTime(mints, burns);
  
  const feesPerShare = collects.map((collect) => {
    const collectTime = parseInt(collect.timestamp);
    
    // Find LP shares at time of collection
    // Use the last share snapshot before or at collection time
    const sharesAtCollection = sharesOverTime
      .filter(s => s.timestamp.getTime() <= collectTime * 1000)
      .slice(-1)[0]?.totalLiquidity || 0;
    
    const feesUSD = parseFloat(collect.amountUSD);
    
    return {
      timestamp: new Date(collectTime * 1000),
      feesUSD,
      sharesAtTime: sharesAtCollection,
      feesPerShare: sharesAtCollection > 0 ? feesUSD / sharesAtCollection : 0,
    };
  });
  
  return feesPerShare;
}
```

## Complete Backtesting Example

```typescript
import { queryTheGraph } from "@/lib/gql.js";

async function backtestStrategyFees(
  poolAddress: string,
  strategyAddress: string
) {
  // 1. Query all events from subgraph
  const query = `
    query BacktestStrategy(
      $poolId: ID!
      $owner: String!
      $first: Int!
    ) {
      collects(
        first: $first
        orderBy: timestamp
        orderDirection: asc
        where: { pool: $poolId, owner: $owner }
      ) {
        id
        timestamp
        amount0
        amount1
        amountUSD
      }
      
      mints(
        first: $first
        orderBy: timestamp
        orderDirection: asc
        where: { pool: $poolId, owner: $owner }
      ) {
        id
        timestamp
        amount
        amountUSD
      }
      
      burns(
        first: $first
        orderBy: timestamp
        orderDirection: asc
        where: { pool: $poolId, owner: $owner }
      ) {
        id
        timestamp
        amount
        amountUSD
      }
    }
  `;
  
  const variables = {
    poolId: poolAddress.toLowerCase(),
    owner: strategyAddress.toLowerCase(),
    first: 1000,
  };
  
  const data = await queryTheGraph(UNISWAP_V3_SUBGRAPH_ID, query, variables);
  
  // 2. Calculate metrics
  const totalFees = calculateTotalFees(data.collects);
  const feesOverTime = calculateFeesOverTime(data.collects);
  const sharesOverTime = calculateLPSharesOverTime(data.mints, data.burns);
  const feesPerShare = calculateFeesPerShare(
    data.collects,
    data.mints,
    data.burns
  );
  
  // 3. Analyze results
  console.log("Total Fees Earned:", totalFees.totalFeesUSD, "USD");
  console.log("Number of Collections:", totalFees.collectionCount);
  console.log("Average Collection Size:", 
    totalFees.totalFeesUSD / totalFees.collectionCount, "USD"
  );
  
  // 4. Calculate performance metrics
  const timeRange = feesOverTime.length > 0
    ? (feesOverTime[feesOverTime.length - 1].timestamp.getTime() - 
       feesOverTime[0].timestamp.getTime()) / (1000 * 60 * 60 * 24)
    : 0; // days
    
  const dailyFees = timeRange > 0 ? totalFees.totalFeesUSD / timeRange : 0;
  const annualizedFees = dailyFees * 365;
  
  console.log("Time Range:", timeRange.toFixed(2), "days");
  console.log("Daily Fees:", dailyFees.toFixed(2), "USD/day");
  console.log("Annualized Fees:", annualizedFees.toFixed(2), "USD/year");
  
  return {
    totalFees,
    feesOverTime,
    sharesOverTime,
    feesPerShare,
    metrics: {
      timeRangeDays: timeRange,
      dailyFees,
      annualizedFees,
    },
  };
}
```

## What You Can Calculate

### 1. Total Fees Earned
- Sum of all `Collect` events
- In USD and token amounts

### 2. Fees Over Time
- Cumulative fees earned
- Daily/weekly/monthly fee rates

### 3. Fees Per LP Share
- How much each LP share earned
- Fair distribution to individual LPs

### 4. Collection Frequency
- How often fees are collected
- Average time between collections

### 5. Performance Metrics
- Annualized fee yield
- Comparison to benchmarks
- Fee collection efficiency

## Benefits of Subgraph-Only Approach

✅ **Simple**: Single data source, no complex syncing
✅ **Fast**: Direct queries, no RPC rate limits
✅ **Complete**: All historical events available
✅ **Free**: No RPC costs
✅ **Reliable**: Subgraph is battle-tested

## Limitations

⚠️ **Indexing Delay**: Subgraph has 2-5 minute delay (not relevant for backtesting)
⚠️ **No Uncollected Fees**: Only shows collected fees (but that's what you earned!)
⚠️ **Position Identification**: Need to query by owner address and filter by tick ranges

## Conclusion

For backtesting your strategy's fee performance, **the subgraph is all you need!**

No live tracking, no RPC queries, no complex state syncing. Just query the events and calculate the metrics you need.



