# Tracking Design for Missing Data

This document designs the tracking system for data that's not available from the subgraph but required for accurate LP fee calculations.

## Missing Data - Context-Dependent

**Key Insight**: What data you need depends on your use case:
- **For Backtesting/Historical Analysis**: Subgraph is **sufficient** ✅
- **For Live Operations/Real-Time UI**: Need contract queries ⚡

### For Backtesting (Subgraph Sufficient)

The subgraph provides everything needed for historical fee analysis:

1. **Historical Fee Collections**
   - ✅ `Collect` events with `amount0`, `amount1`, `amountUSD`
   - ✅ Timestamps for when fees were collected
   - ✅ Tick ranges at collection time

2. **Historical Position Changes**
   - ✅ `Mint` events (liquidity additions)
   - ✅ `Burn` events (liquidity removals)
   - ✅ Timestamps and amounts for each event

3. **Historical Position State**
   - ✅ `PositionSnapshot` at various blocks
   - ✅ `collectedFeesToken0` / `collectedFeesToken1` (cumulative)
   - ✅ Historical tick ranges and liquidity

**Conclusion for Backtesting**: Subgraph has all the data you need! No live tracking required.

### For Live Operations (Need Contract Queries)

These are only needed if you want **real-time** data:

1. **Current Fee Growth Inside**
   - **Why Missing**: Subgraph has indexing delay (2-5 minutes)
   - **Needed For**: Real-time uncollected fee calculation
   - **Source**: Contract state (`pool.positions()` mapping)

2. **Current Uncollected Fees**
   - **Why Missing**: Subgraph only shows collected fees, not uncollected
   - **Needed For**: Current fee balance for LPs
   - **Source**: Contract state (`tokensOwed0`, `tokensOwed1` from `pool.positions()`)

3. **Current Tick Ranges (After Rebalancing)**
   - **Why Missing**: Subgraph position data updates with delay
   - **Needed For**: Identifying main vs alt positions, calculating position value
   - **Source**: Contract state (`strategy.positionMain()`, `strategy.positionAlt()`)

4. **Current Liquidity Amounts**
   - **Why Missing**: Subgraph position updates lag
   - **Needed For**: Real-time position value and share calculations
   - **Source**: Contract state (`pool.positions()` or aggregated from strategy)

## Historical vs Live Tracking

### ✅ For Backtesting: Subgraph is Sufficient!

**You don't need live tracking for backtesting!**

The subgraph provides:
- ✅ All historical `Collect` events (fees collected)
- ✅ All historical `Mint`/`Burn` events (position changes)
- ✅ Historical `PositionSnapshot` data
- ✅ Historical pool state

**What you can calculate from subgraph alone:**
```typescript
// Total fees earned by strategy
const totalFees = collects.reduce((sum, collect) => 
  sum + parseFloat(collect.amountUSD), 0
);

// Fees per LP share over time
const feesPerShare = collects.map(collect => ({
  timestamp: collect.timestamp,
  feesUSD: collect.amountUSD,
  // Calculate LP shares at this time from Mint/Burn events
  sharesAtTime: calculateLPSharesAtBlock(collect.blockNumber),
  feesPerShare: collect.amountUSD / calculateLPSharesAtBlock(collect.blockNumber)
}));
```

### Historical Tracking via RPC (If Needed)

If you need data not in subgraph or want to validate:

**Methods:**
1. **Contract State at Block**: Query contract state at any past block number
   ```typescript
   await contract.read.functionName({ blockNumber: pastBlock })
   ```

2. **Event Logs**: Use `getLogs` to fetch historical events
   ```typescript
   await client.getLogs({
     address: contractAddress,
     event: eventAbi,
     fromBlock: historicalBlock,
     toBlock: targetBlock,
   })
   ```

**Advantages:**
- ✅ Can backfill any historical period
- ✅ No dependency on subgraph indexing
- ✅ Complete historical accuracy
- ✅ Can rebuild database from scratch

**Disadvantages:**
- ⚠️ Slower (many RPC calls)
- ⚠️ RPC rate limits
- ⚠️ More expensive (if using paid RPC)

### ⚡ Live Tracking

**Real-time monitoring as events occur**

**Methods:**
1. **Block Polling**: Poll new blocks every ~2 seconds
2. **Event Listening**: Watch for specific events (deposit, withdraw, rebalance, harvest)
3. **State Polling**: Periodically query current contract state

**Advantages:**
- ✅ Real-time updates
- ✅ Lower latency
- ✅ Efficient (only process new data)

**Disadvantages:**
- ⚠️ Requires continuous running service
- ⚠️ Can miss data if service is down
- ⚠️ Need to catch up on missed blocks

## Recommended Approach: Subgraph-First for Backtesting

### For Backtesting (Recommended)

**Use subgraph only - it's sufficient!**

1. **Query All Historical Events**
   ```graphql
   query GetAllStrategyEvents($poolId: ID!, $strategyAddress: String!) {
     collects(where: { pool: $poolId, owner: $strategyAddress }) {
       id, timestamp, amount0, amount1, amountUSD, tickLower, tickUpper
     }
     mints(where: { pool: $poolId, owner: $strategyAddress }) {
       id, timestamp, amount, amount0, amount1, amountUSD
     }
     burns(where: { pool: $poolId, owner: $strategyAddress }) {
       id, timestamp, amount, amount0, amount1, amountUSD
     }
   }
   ```

2. **Calculate Fees Over Time**
   - Sum `Collect` events to get total fees earned
   - Track LP shares from `Mint`/`Burn` events
   - Calculate fees per share at each collection

3. **Backtest Algorithm Performance**
   - Compare fees earned vs benchmark
   - Analyze fee collection frequency
   - Track position value over time

**No RPC needed for backtesting!** ✅

### For Live Operations (If Needed Later)

Only needed if you want real-time data display:

1. **Periodic Contract Queries** (every 5-15 minutes)
   - Current uncollected fees
   - Current tick ranges
   - Current liquidity

2. **Event Monitoring** (optional)
   - Watch for new Collect events
   - Watch for rebalance events

## Tracking Architecture

### 1. Strategy State Tracker Service

```typescript
// apps/server/src/services/defi/strategy-state-tracker.service.ts

export class StrategyStateTrackerService {
  /**
   * Historical backfill: Query contract state at specific blocks
   */
  async getHistoricalState(
    strategyAddress: string,
    blockNumber: bigint
  ): Promise<StrategyState> {
    // Query contract at specific block
    const [pool, positionMain, positionAlt, balances] = await Promise.all([
      this.getPoolAtBlock(strategyAddress, blockNumber),
      this.getPositionMainAtBlock(strategyAddress, blockNumber),
      this.getPositionAltAtBlock(strategyAddress, blockNumber),
      this.getBalancesAtBlock(strategyAddress, blockNumber),
    ]);
    
    // Query fee growth from pool contract
    const feeGrowth = await this.getFeeGrowthAtBlock(
      pool,
      positionMain,
      positionAlt,
      blockNumber
    );
    
    return {
      blockNumber,
      timestamp: await this.getBlockTimestamp(blockNumber),
      pool,
      positionMain,
      positionAlt,
      balances,
      feeGrowth,
    };
  }
  
  /**
   * Live tracking: Get current state
   */
  async getCurrentState(strategyAddress: string): Promise<StrategyState> {
    const currentBlock = await baseClient.getBlockNumber();
    return this.getHistoricalState(strategyAddress, currentBlock);
  }
  
  /**
   * Backfill state for a range of blocks
   */
  async backfillStateRange(
    strategyAddress: string,
    fromBlock: bigint,
    toBlock: bigint,
    step: number = 100 // Process every N blocks
  ): Promise<StrategyState[]> {
    const states: StrategyState[] = [];
    
    for (let block = fromBlock; block <= toBlock; block += BigInt(step)) {
      try {
        const state = await this.getHistoricalState(strategyAddress, block);
        states.push(state);
      } catch (error) {
        logger.error(`Failed to fetch state at block ${block}:`, error);
        // Continue with next block
      }
    }
    
    return states;
  }
}
```

### 2. Event-Based State Updates

```typescript
// Track state changes triggered by events

export class StrategyEventTracker {
  /**
   * Process mint event (liquidity added)
   */
  async onMint(event: MintEvent, log: Log) {
    // Fetch state before and after mint
    const stateBefore = await this.getStateAtBlock(log.blockNumber - 1n);
    const stateAfter = await this.getStateAtBlock(log.blockNumber);
    
    // Calculate changes
    const liquidityDelta = stateAfter.totalLiquidity - stateBefore.totalLiquidity;
    const amount0Delta = stateAfter.balances.amount0 - stateBefore.balances.amount0;
    const amount1Delta = stateAfter.balances.amount1 - stateBefore.balances.amount1;
    
    // Store snapshot
    await this.createStateSnapshot({
      blockNumber: log.blockNumber,
      eventType: 'mint',
      transactionHash: log.transactionHash,
      liquidityDelta,
      amount0Delta,
      amount1Delta,
      stateBefore,
      stateAfter,
    });
  }
  
  /**
   * Process burn event (liquidity removed)
   */
  async onBurn(event: BurnEvent, log: Log) {
    // Similar to onMint but for withdrawals
  }
  
  /**
   * Process collect event (fees harvested)
   */
  async onCollect(event: CollectEvent, log: Log) {
    // Track fee collection
    const stateBefore = await this.getStateAtBlock(log.blockNumber - 1n);
    const stateAfter = await this.getStateAtBlock(log.blockNumber);
    
    const feesCollected0 = event.amount0;
    const feesCollected1 = event.amount1;
    
    await this.createFeeCollectionRecord({
      blockNumber: log.blockNumber,
      transactionHash: log.transactionHash,
      feesCollected0,
      feesCollected1,
      stateBefore,
      stateAfter,
    });
  }
  
  /**
   * Process rebalance (moveTicks called)
   */
  async onRebalance(log: Log) {
    // Detect rebalance by analyzing state changes
    const stateBefore = await this.getStateAtBlock(log.blockNumber - 1n);
    const stateAfter = await this.getStateAtBlock(log.blockNumber);
    
    const tickRangesChanged = 
      stateBefore.positionMain.tickLower !== stateAfter.positionMain.tickLower ||
      stateBefore.positionMain.tickUpper !== stateAfter.positionMain.tickUpper ||
      stateBefore.positionAlt.tickLower !== stateAfter.positionAlt.tickLower ||
      stateBefore.positionAlt.tickUpper !== stateAfter.positionAlt.tickUpper;
    
    if (tickRangesChanged) {
      await this.createRebalanceRecord({
        blockNumber: log.blockNumber,
        transactionHash: log.transactionHash,
        oldPositionMain: stateBefore.positionMain,
        newPositionMain: stateAfter.positionMain,
        oldPositionAlt: stateBefore.positionAlt,
        newPositionAlt: stateAfter.positionAlt,
      });
    }
  }
}
```

### 3. Periodic State Sync

```typescript
// Sync strategy state periodically

export class StrategyStateSyncService {
  /**
   * Sync all active strategies
   */
  async syncAllStrategies() {
    const strategies = await this.getActiveStrategies();
    
    for (const strategy of strategies) {
      try {
        await this.syncStrategy(strategy.address);
      } catch (error) {
        logger.error(`Failed to sync strategy ${strategy.address}:`, error);
      }
    }
  }
  
  /**
   * Sync single strategy state
   */
  async syncStrategy(strategyAddress: string) {
    // 1. Get current state from contract
    const currentState = await this.getCurrentState(strategyAddress);
    
    // 2. Get last synced state from database
    const lastSnapshot = await this.getLastSnapshot(strategyAddress);
    
    // 3. If state changed, create new snapshot
    if (this.hasStateChanged(lastSnapshot, currentState)) {
      await this.createStateSnapshot(currentState);
      
      // 4. Calculate fees for all LPs since last snapshot
      await this.calculateFeesForLPs(strategyAddress, lastSnapshot, currentState);
    }
    
    // 5. Update last sync timestamp
    await this.updateLastSync(strategyAddress);
  }
}
```

## Data Sources Priority

### For Historical Data (Past Events)
1. **Primary**: Event logs via `getLogs` (most reliable)
2. **Secondary**: Subgraph events (faster, but may have gaps)
3. **Validation**: Contract state queries at event blocks

### For Current State
1. **Primary**: Direct contract queries (real-time)
2. **Secondary**: Latest subgraph data (with delay awareness)
3. **Fallback**: Last known state + event diffs

## Implementation Strategy

### Step 1: Initial Backfill (One-time)

```typescript
async function initialBackfill(strategyAddress: string, deploymentBlock: bigint) {
  const currentBlock = await baseClient.getBlockNumber();
  
  // 1. Get all relevant events from logs
  const events = await fetchAllEvents(strategyAddress, deploymentBlock, currentBlock);
  
  // 2. For each event, query state at that block
  const snapshots = [];
  for (const event of events) {
    const state = await getStateAtBlock(strategyAddress, event.blockNumber);
    snapshots.push({
      ...state,
      eventType: event.type,
      eventData: event.data,
    });
  }
  
  // 3. Store all snapshots in database
  await prisma.strategyStateSnapshot.createMany({
    data: snapshots,
  });
  
  // 4. Calculate LP positions from snapshots
  await calculateInitialLPPositions(strategyAddress, snapshots);
}
```

### Step 2: Live Event Tracking (Ongoing)

```typescript
// Use existing tx-listener.ts pattern

export const strategyMintHandler: TopicHandler = {
  signature: "Mint(address,address,int24,int24,uint128,uint256,uint256)",
  contract: STRATEGY_CONTRACT,
  decoder: decodeMintLog,
  handler: async (decoded, log) => {
    await strategyEventTracker.onMint(decoded, log);
  },
};

export const strategyBurnHandler: TopicHandler = {
  signature: "Burn(address,int24,int24,uint128,uint256,uint256)",
  contract: STRATEGY_CONTRACT,
  decoder: decodeBurnLog,
  handler: async (decoded, log) => {
    await strategyEventTracker.onBurn(decoded, log);
  },
};

export const strategyCollectHandler: TopicHandler = {
  signature: "Collect(address,address,int24,int24,uint256,uint256)",
  contract: STRATEGY_CONTRACT,
  decoder: decodeCollectLog,
  handler: async (decoded, log) => {
    await strategyEventTracker.onCollect(decoded, log);
  },
};

// Also track Uniswap pool events
export const poolMintHandler: TopicHandler = {
  signature: "Mint(address,address,int24,int24,uint128,uint256,uint256)",
  contract: POOL_CONTRACT, // Will be strategy-specific
  decoder: decodePoolMintLog,
  handler: async (decoded, log) => {
    // Check if this mint is from our strategy
    if (decoded.owner.toLowerCase() === strategyAddress.toLowerCase()) {
      await strategyEventTracker.onMint(decoded, log);
    }
  },
};
```

### Step 3: Periodic State Sync (Scheduled Task)

```typescript
// Run every 5-15 minutes

export async function syncStrategyStates() {
  const syncService = new StrategyStateSyncService();
  await syncService.syncAllStrategies();
}

// Schedule via existing scheduler
// See apps/server/src/services/tasks/ for scheduling patterns
```

## Query Contract State at Block

### Example Implementation

```typescript
import { getContract } from "viem";
import { baseClient } from "@/lib/rpc.js";

async function getStateAtBlock(
  strategyAddress: string,
  blockNumber: bigint
): Promise<StrategyState> {
  const strategyContract = getContract({
    address: strategyAddress as `0x${string}`,
    abi: STRATEGY_ABI,
    client: baseClient,
  });
  
  // Query at specific block
  const [pool, positionMain, positionAlt, balances] = await Promise.all([
    strategyContract.read.pool({ blockNumber }),
    strategyContract.read.positionMain({ blockNumber }),
    strategyContract.read.positionAlt({ blockNumber }),
    strategyContract.read.balances({ blockNumber }),
  ]);
  
  // Query pool contract for fee growth
  const poolContract = getContract({
    address: pool as `0x${string}`,
    abi: UNISWAP_POOL_ABI,
    client: baseClient,
  });
  
  const [slot0, positionInfoMain, positionInfoAlt] = await Promise.all([
    poolContract.read.slot0({ blockNumber }),
    poolContract.read.positions({
      blockNumber,
      args: [
        keccak256(encodePacked(
          ["address", "int24", "int24"],
          [strategyAddress, positionMain.tickLower, positionMain.tickUpper]
        ))
      ],
    }),
    poolContract.read.positions({
      blockNumber,
      args: [
        keccak256(encodePacked(
          ["address", "int24", "int24"],
          [strategyAddress, positionAlt.tickLower, positionAlt.tickUpper]
        ))
      ],
    }),
  ]);
  
  return {
    blockNumber,
    pool,
    positionMain: {
      ...positionMain,
      liquidity: positionInfoMain.liquidity,
      feeGrowthInside0LastX128: positionInfoMain.feeGrowthInside0LastX128,
      feeGrowthInside1LastX128: positionInfoMain.feeGrowthInside1LastX128,
      tokensOwed0: positionInfoMain.tokensOwed0,
      tokensOwed1: positionInfoMain.tokensOwed1,
    },
    positionAlt: {
      ...positionAlt,
      liquidity: positionInfoAlt.liquidity,
      feeGrowthInside0LastX128: positionInfoAlt.feeGrowthInside0LastX128,
      feeGrowthInside1LastX128: positionInfoAlt.feeGrowthInside1LastX128,
      tokensOwed0: positionInfoAlt.tokensOwed0,
      tokensOwed1: positionInfoAlt.tokensOwed1,
    },
    currentTick: slot0.tick,
    sqrtPriceX96: slot0.sqrtPriceX96,
    balances,
  };
}
```

## Performance Considerations

### Batch Queries
- Use `Promise.all()` for parallel queries
- Batch multiple strategy queries together
- Cache frequently accessed data

### Rate Limiting
- Implement request throttling
- Use connection pooling
- Consider using multiple RPC endpoints

### Incremental Sync
- Only process new blocks since last sync
- Use checkpoints to resume from last position
- Handle reorgs gracefully

### Caching Strategy
- Cache contract ABIs
- Cache pool addresses
- Cache recent block timestamps

## Summary

### For Backtesting: Subgraph is Sufficient! ✅

**Answer: No RPC needed for backtesting!**

**Recommended Approach:**
1. ✅ **Use Subgraph Only**: Query all historical Collect, Mint, Burn events
2. ✅ **Calculate Fees**: Sum Collect events to get total fees earned
3. ✅ **Track LP Shares**: Calculate shares from Mint/Burn events
4. ✅ **Analyze Performance**: Calculate fees per share, compare to benchmarks

**Benefits:**
- ✅ Simple and fast (single data source)
- ✅ Complete historical data
- ✅ No RPC costs or rate limits
- ✅ Reliable and proven data source

### For Live Operations: RPC Needed ⚡

Only if you need real-time data later:

1. ✅ **Periodic Contract Queries**: Every 5-15 minutes for current state
2. ✅ **Event Monitoring**: Watch for new events as they occur
3. ✅ **Hybrid Approach**: Subgraph for history, RPC for current state

**Trade-offs for Live:**
- More RPC calls (cost and rate limits)
- Need robust error handling
- Requires ongoing service

**Conclusion**: For backtesting your algorithm's fee performance, the subgraph provides everything you need. No live tracking required!


