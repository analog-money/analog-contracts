# LP Tracking Data Model for Concentrated Liquidity

This document defines the data model for tracking individual Liquidity Provider (LP) positions and calculating fees for each user in our concentrated liquidity strategy.

## Data Sources

We use a hybrid approach:
- **Uniswap V3 Subgraph**: Historical events (mint, burn, collect), position snapshots, pool metrics
- **Direct Contract Queries**: Current state (fee growth, tick ranges, liquidity)
- **Database**: Store processed data, user positions, and calculated fees

See `SUBGRAPH_DATA_AVAILABILITY.md` for details on what's available from the subgraph.

## Overview

The strategy manages aggregated liquidity positions on Uniswap V3 (main + alt positions). We need to:
1. Track each user's deposit/withdrawal history
2. Calculate each user's share of the total position at any point in time
3. Track fee accumulation over time
4. Attribute fees to users based on their liquidity shares
5. Handle rebalancing events that change position ranges

## Core Data Models

### 1. LP Position (User's Investment)

Tracks each user's stake in the strategy:

```typescript
model LPPosition {
  id                    String    @id @default(cuid())
  userId                String
  strategyId            String    // Reference to Strategy
  
  // Current position state
  shares                String    @default("0") // Total shares owned (similar to vault shares)
  liquidityShare        String    @default("0") // Current liquidity share in Uniswap positions
  
  // Token amounts at last snapshot
  amount0               String    @default("0") // token0 amount
  amount1               String    @default("0") // token1 amount
  
  // Fee tracking
  lastFeeGrowthInside0X128 String @default("0") // Last recorded fee growth for token0
  lastFeeGrowthInside1X128 String @default("0") // Last recorded fee growth for token1
  uncollectedFees0      String    @default("0") // Accumulated uncollected fees token0
  uncollectedFees1      String    @default("0") // Accumulated uncollected fees token1
  
  // Historical totals
  totalFeesEarned0      String    @default("0") // Lifetime fees earned (token0)
  totalFeesEarned1      String    @default("0") // Lifetime fees earned (token1)
  totalFeesEarnedUSD    String    @default("0") // Lifetime fees in USD
  
  // Timestamps
  createdAt             DateTime  @default(now())
  updatedAt             DateTime  @updatedAt
  lastSnapshotAt        DateTime  @default(now())
  
  // Relations
  user                  User      @relation(fields: [userId], references: [id])
  strategy              Strategy  @relation(fields: [strategyId], references: [id])
  deposits              LPDeposit[]
  withdrawals          LPWithdrawal[]
  feeSnapshots          LPFeeSnapshot[]
  
  @@unique([userId, strategyId])
  @@index([userId])
  @@index([strategyId])
  @@index([lastSnapshotAt])
}
```

### 2. Strategy Position Snapshot

Tracks the strategy's aggregated positions on Uniswap V3 at each point in time:

```typescript
model StrategyPositionSnapshot {
  id                    String    @id @default(cuid())
  strategyId            String
  
  // Position ranges (main + alt are tracked separately in strategy contract)
  // We track the aggregated view
  tickLowerMain         Int       // Main position lower tick
  tickUpperMain         Int       // Main position upper tick
  tickLowerAlt          Int       // Alt position lower tick
  tickUpperAlt          Int       // Alt position upper tick
  
  // Pool state at snapshot
  poolAddress           String
  currentTick           Int
  sqrtPriceX96          String
  isInRange             Boolean   // Is price within main position range?
  
  // Aggregated liquidity
  liquidityMain         String    // Main position liquidity
  liquidityAlt          String    // Alt position liquidity
  totalLiquidity        String    // Sum of both positions
  
  // Token amounts
  amount0Main           String
  amount1Main           String
  amount0Alt            String
  amount1Alt            String
  totalAmount0          String    // Sum of both positions
  totalAmount1          String    // Sum of both positions
  
  // Fee growth tracking (from pool)
  feeGrowthGlobal0X128  String    // Global fee growth token0
  feeGrowthGlobal1X128  String    // Global fee growth token1
  feeGrowthInsideMain0X128 String // Fee growth inside main position (token0)
  feeGrowthInsideMain1X128 String // Fee growth inside main position (token1)
  feeGrowthInsideAlt0X128 String  // Fee growth inside alt position (token0)
  feeGrowthInsideAlt1X128 String  // Fee growth inside alt position (token1)
  
  // Uncollected fees in strategy
  uncollectedFees0      String    // Total uncollected fees token0
  uncollectedFees1      String    // Total uncollected fees token1
  
  // Price calculations
  priceLower            Float     // Lower price bound (main position)
  priceUpper            Float     // Upper price bound (main position)
  priceCurrent          Float
  
  // Value calculations
  positionValueUSD      String    // Total position value in USD
  
  // Snapshot metadata
  blockNumber           BigInt
  transactionHash       String?
  snapshotType          SnapshotType // DEPOSIT, WITHDRAWAL, REBALANCE, HARVEST, MANUAL
  createdAt             DateTime  @default(now())
  
  // Relations
  strategy              Strategy  @relation(fields: [strategyId], references: [id])
  lpFeeSnapshots        LPFeeSnapshot[]
  
  @@index([strategyId])
  @@index([blockNumber])
  @@index([createdAt])
  @@index([snapshotType])
}

enum SnapshotType {
  DEPOSIT      // User deposit occurred
  WITHDRAWAL   // User withdrawal occurred
  REBALANCE    // Position rebalanced (moveTicks called)
  HARVEST      // Fees harvested
  MANUAL       // Manual snapshot for fee calculation
}
```

### 3. LP Deposit/Withdrawal Events

Tracks all user deposit and withdrawal events:

```typescript
model LPDeposit {
  id                    String    @id @default(cuid())
  lpPositionId          String
  strategyId            String
  
  // Deposit amounts
  amount0               String    // token0 deposited
  amount1               String    // token1 deposited
  sharesMinted          String    // Shares minted to user
  
  // Position state at deposit
  liquidityBefore       String    // Total liquidity before deposit
  liquidityAfter        String    // Total liquidity after deposit
  liquidityShareBefore  String    // User's liquidity share before
  liquidityShareAfter   String    // User's liquidity share after
  
  // Fee state at deposit
  feeGrowthInside0X128  String    // Fee growth at time of deposit
  feeGrowthInside1X128  String
  
  // Transaction details
  transactionHash       String    @unique
  blockNumber           BigInt
  blockTimestamp        DateTime
  
  // Relations
  lpPosition            LPPosition @relation(fields: [lpPositionId], references: [id])
  strategy              Strategy   @relation(fields: [strategyId], references: [id])
  
  @@index([lpPositionId])
  @@index([strategyId])
  @@index([blockNumber])
  @@index([blockTimestamp])
}

model LPWithdrawal {
  id                    String    @id @default(cuid())
  lpPositionId          String
  strategyId            String
  
  // Withdrawal amounts
  sharesBurned          String    // Shares burned from user
  amount0               String    // token0 withdrawn
  amount1               String    // token1 withdrawn
  
  // Position state at withdrawal
  liquidityBefore       String
  liquidityAfter        String
  liquidityShareBefore  String
  liquidityShareAfter   String
  
  // Fee state at withdrawal
  feeGrowthInside0X128  String
  feeGrowthInside1X128  String
  feesCollected0        String    // Fees collected with this withdrawal
  feesCollected1        String
  
  // Transaction details
  transactionHash       String    @unique
  blockNumber           BigInt
  blockTimestamp        DateTime
  
  // Relations
  lpPosition            LPPosition @relation(fields: [lpPositionId], references: [id])
  strategy              Strategy   @relation(fields: [strategyId], references: [id])
  
  @@index([lpPositionId])
  @@index([strategyId])
  @@index([blockNumber])
  @@index([blockTimestamp])
}
```

### 4. LP Fee Snapshot

Tracks fee accrual for each LP at each strategy snapshot:

```typescript
model LPFeeSnapshot {
  id                    String    @id @default(cuid())
  lpPositionId          String
  strategySnapshotId    String
  
  // User's position at snapshot
  shares                String
  liquidityShare        String
  liquiditySharePercent Float     // Percentage of total liquidity (0-1)
  
  // Token amounts
  amount0               String
  amount1               String
  
  // Fee calculations
  feeGrowthInside0X128  String    // Fee growth inside position at snapshot
  feeGrowthInside1X128  String
  feesAccrued0          String    // Fees accrued since last snapshot (token0)
  feesAccrued1          String    // Fees accrued since last snapshot (token1)
  feesAccruedUSD        String    // Fees accrued in USD
  
  // Cumulative totals
  totalFeesEarned0      String    // Total lifetime fees (token0)
  totalFeesEarned1      String    // Total lifetime fees (token1)
  totalFeesEarnedUSD    String    // Total lifetime fees (USD)
  
  // Uncollected fees
  uncollectedFees0      String
  uncollectedFees1      String
  
  // Position value
  positionValueUSD      String
  
  // Snapshot metadata
  createdAt             DateTime  @default(now())
  
  // Relations
  lpPosition            LPPosition @relation(fields: [lpPositionId], references: [id])
  strategySnapshot      StrategyPositionSnapshot @relation(fields: [strategySnapshotId], references: [id])
  
  @@index([lpPositionId])
  @@index([strategySnapshotId])
  @@index([createdAt])
}
```

### 5. Strategy Aggregate Tracking

High-level tracking of the strategy's overall state:

```typescript
model StrategyAggregate {
  id                    String    @id @default(cuid())
  strategyId            String    @unique
  
  // Current aggregated state
  totalShares           String    @default("0") // Total shares minted
  totalLiquidity        String    @default("0") // Total liquidity in Uniswap
  totalAmount0          String    @default("0")
  totalAmount1          String    @default("0")
  
  // Current fee state
  feeGrowthInside0X128  String    @default("0")
  feeGrowthInside1X128  String    @default("0")
  uncollectedFees0      String    @default("0")
  uncollectedFees1      String    @default("0")
  
  // Lifetime totals
  totalFeesCollected0   String    @default("0")
  totalFeesCollected1   String    @default("0")
  totalFeesCollectedUSD String    @default("0")
  
  // Performance metrics
  totalValueUSD         String    @default("0")
  estimatedAPR          Float?
  
  // Timestamps
  lastHarvestAt         DateTime?
  lastRebalanceAt       DateTime?
  lastSnapshotAt        DateTime  @default(now())
  updatedAt             DateTime  @updatedAt
  
  // Relations
  strategy              Strategy  @relation(fields: [strategyId], references: [id])
  
  @@index([strategyId])
}
```

## Fee Calculation Algorithm

### 1. On Deposit

```typescript
async function handleDeposit(
  userId: string,
  strategyId: string,
  amount0: BigInt,
  amount1: BigInt,
  txHash: string,
  blockNumber: bigint
) {
  // 1. Get current strategy state
  const strategySnapshot = await getLatestStrategySnapshot(strategyId);
  const lpPosition = await getOrCreateLPPosition(userId, strategyId);
  
  // 2. Calculate shares to mint (based on deposit amount vs total value)
  const totalValue = strategySnapshot.totalAmount0 * price0 + strategySnapshot.totalAmount1 * price1;
  const depositValue = amount0 * price0 + amount1 * price1;
  const sharesMinted = totalValue > 0
    ? (depositValue * strategySnapshot.totalShares) / totalValue
    : depositValue; // First deposit
  
  // 3. Calculate liquidity share (proportional to shares)
  const liquidityShare = (sharesMinted * strategySnapshot.totalLiquidity) / 
    (strategySnapshot.totalShares + sharesMinted);
  
  // 4. Create deposit event
  await createLPDeposit({
    lpPositionId: lpPosition.id,
    amount0,
    amount1,
    sharesMinted,
    liquidityBefore: strategySnapshot.totalLiquidity,
    liquidityAfter: strategySnapshot.totalLiquidity + liquidityShare,
    liquidityShareBefore: lpPosition.liquidityShare,
    liquidityShareAfter: lpPosition.liquidityShare + liquidityShare,
    feeGrowthInside0X128: strategySnapshot.feeGrowthInsideMain0X128,
    feeGrowthInside1X128: strategySnapshot.feeGrowthInsideMain1X128,
    transactionHash: txHash,
    blockNumber,
  });
  
  // 5. Update LP position
  await updateLPPosition(lpPosition.id, {
    shares: lpPosition.shares + sharesMinted,
    liquidityShare: lpPosition.liquidityShare + liquidityShare,
    amount0: lpPosition.amount0 + amount0,
    amount1: lpPosition.amount1 + amount1,
    lastFeeGrowthInside0X128: strategySnapshot.feeGrowthInsideMain0X128,
    lastFeeGrowthInside1X128: strategySnapshot.feeGrowthInsideMain1X128,
    lastSnapshotAt: new Date(),
  });
  
  // 6. Update strategy aggregate
  await updateStrategyAggregate(strategyId, {
    totalShares: strategySnapshot.totalShares + sharesMinted,
    totalLiquidity: strategySnapshot.totalLiquidity + liquidityShare,
    totalAmount0: strategySnapshot.totalAmount0 + amount0,
    totalAmount1: strategySnapshot.totalAmount1 + amount1,
  });
  
  // 7. Create strategy snapshot
  await createStrategySnapshot(strategyId, {
    snapshotType: 'DEPOSIT',
    transactionHash: txHash,
    blockNumber,
    // ... current state from contract
  });
}
```

### 2. Fee Accrual Calculation

```typescript
async function calculateFeesForLP(
  lpPositionId: string,
  currentStrategySnapshot: StrategyPositionSnapshot
) {
  const lpPosition = await getLPPosition(lpPositionId);
  const lastSnapshot = await getLastLPFeeSnapshot(lpPositionId);
  
  // If no previous snapshot, use position's last recorded values
  const lastFeeGrowth0 = lastSnapshot 
    ? lastSnapshot.feeGrowthInside0X128
    : lpPosition.lastFeeGrowthInside0X128;
  const lastFeeGrowth1 = lastSnapshot
    ? lastSnapshot.feeGrowthInside1X128
    : lpPosition.lastFeeGrowthInside1X128;
  
  // Get current fee growth inside position range
  // Need to calculate weighted average for main + alt positions
  const currentFeeGrowth0 = calculateWeightedFeeGrowth(
    currentStrategySnapshot.feeGrowthInsideMain0X128,
    currentStrategySnapshot.feeGrowthInsideAlt0X128,
    currentStrategySnapshot.liquidityMain,
    currentStrategySnapshot.liquidityAlt
  );
  const currentFeeGrowth1 = calculateWeightedFeeGrowth(
    currentStrategySnapshot.feeGrowthInsideMain1X128,
    currentStrategySnapshot.feeGrowthInsideAlt1X128,
    currentStrategySnapshot.liquidityMain,
    currentStrategySnapshot.liquidityAlt
  );
  
  // Calculate fee growth delta
  const feeGrowthDelta0 = currentFeeGrowth0 - lastFeeGrowth0;
  const feeGrowthDelta1 = currentFeeGrowth1 - lastFeeGrowth1;
  
  // Calculate fees accrued = delta * user's liquidity share
  const feesAccrued0 = (feeGrowthDelta0 * lpPosition.liquidityShare) / (2n ** 128n);
  const feesAccrued1 = (feeGrowthDelta1 * lpPosition.liquidityShare) / (2n ** 128n);
  
  // Update LP position
  const totalFees0 = lpPosition.totalFeesEarned0 + feesAccrued0;
  const totalFees1 = lpPosition.totalFeesEarned1 + feesAccrued1;
  const uncollected0 = lpPosition.uncollectedFees0 + feesAccrued0;
  const uncollected1 = lpPosition.uncollectedFees1 + feesAccrued1;
  
  // Convert to USD (for reporting)
  const feesAccruedUSD = (feesAccrued0 * price0USD) + (feesAccrued1 * price1USD);
  const totalFeesUSD = (totalFees0 * price0USD) + (totalFees1 * price1USD);
  
  // Create fee snapshot
  await createLPFeeSnapshot({
    lpPositionId,
    strategySnapshotId: currentStrategySnapshot.id,
    shares: lpPosition.shares,
    liquidityShare: lpPosition.liquidityShare,
    liquiditySharePercent: (lpPosition.liquidityShare * 100n) / currentStrategySnapshot.totalLiquidity,
    amount0: lpPosition.amount0,
    amount1: lpPosition.amount1,
    feeGrowthInside0X128: currentFeeGrowth0.toString(),
    feeGrowthInside1X128: currentFeeGrowth1.toString(),
    feesAccrued0: feesAccrued0.toString(),
    feesAccrued1: feesAccrued1.toString(),
    feesAccruedUSD: feesAccruedUSD.toString(),
    totalFeesEarned0: totalFees0.toString(),
    totalFeesEarned1: totalFees1.toString(),
    totalFeesEarnedUSD: totalFeesUSD.toString(),
    uncollectedFees0: uncollected0.toString(),
    uncollectedFees1: uncollected1.toString(),
  });
  
  // Update LP position
  await updateLPPosition(lpPositionId, {
    lastFeeGrowthInside0X128: currentFeeGrowth0.toString(),
    lastFeeGrowthInside1X128: currentFeeGrowth1.toString(),
    uncollectedFees0: uncollected0.toString(),
    uncollectedFees1: uncollected1.toString(),
    totalFeesEarned0: totalFees0.toString(),
    totalFeesEarned1: totalFees1.toString(),
    totalFeesEarnedUSD: totalFeesUSD.toString(),
    lastSnapshotAt: new Date(),
  });
}

function calculateWeightedFeeGrowth(
  feeGrowthMain: bigint,
  feeGrowthAlt: bigint,
  liquidityMain: bigint,
  liquidityAlt: bigint
): bigint {
  const totalLiquidity = liquidityMain + liquidityAlt;
  if (totalLiquidity === 0n) return 0n;
  
  return (feeGrowthMain * liquidityMain + feeGrowthAlt * liquidityAlt) / totalLiquidity;
}
```

### 3. On Withdrawal

```typescript
async function handleWithdrawal(
  userId: string,
  strategyId: string,
  sharesBurned: BigInt,
  amount0: BigInt,
  amount1: BigInt,
  txHash: string,
  blockNumber: bigint
) {
  // 1. Calculate fees before withdrawal (claim fees)
  const strategySnapshot = await getLatestStrategySnapshot(strategyId);
  await calculateFeesForAllLPs(strategyId, strategySnapshot.id);
  
  // 2. Get LP position
  const lpPosition = await getLPPositionByUser(userId, strategyId);
  
  // 3. Calculate liquidity share to remove (proportional to shares)
  const liquidityShareRemoved = (sharesBurned * lpPosition.liquidityShare) / lpPosition.shares;
  
  // 4. Calculate fees collected (proportional to shares withdrawn)
  const feesCollected0 = (sharesBurned * lpPosition.uncollectedFees0) / lpPosition.shares;
  const feesCollected1 = (sharesBurned * lpPosition.uncollectedFees1) / lpPosition.shares;
  
  // 5. Create withdrawal event
  await createLPWithdrawal({
    lpPositionId: lpPosition.id,
    sharesBurned,
    amount0,
    amount1,
    liquidityBefore: strategySnapshot.totalLiquidity,
    liquidityAfter: strategySnapshot.totalLiquidity - liquidityShareRemoved,
    liquidityShareBefore: lpPosition.liquidityShare,
    liquidityShareAfter: lpPosition.liquidityShare - liquidityShareRemoved,
    feeGrowthInside0X128: strategySnapshot.feeGrowthInsideMain0X128,
    feeGrowthInside1X128: strategySnapshot.feeGrowthInsideMain1X128,
    feesCollected0,
    feesCollected1,
    transactionHash: txHash,
    blockNumber,
  });
  
  // 6. Update LP position
  await updateLPPosition(lpPosition.id, {
    shares: lpPosition.shares - sharesBurned,
    liquidityShare: lpPosition.liquidityShare - liquidityShareRemoved,
    amount0: lpPosition.amount0 - amount0,
    amount1: lpPosition.amount1 - amount1,
    uncollectedFees0: lpPosition.uncollectedFees0 - feesCollected0,
    uncollectedFees1: lpPosition.uncollectedFees1 - feesCollected1,
    lastSnapshotAt: new Date(),
  });
  
  // 7. Update strategy aggregate
  await updateStrategyAggregate(strategyId, {
    totalShares: strategySnapshot.totalShares - sharesBurned,
    totalLiquidity: strategySnapshot.totalLiquidity - liquidityShareRemoved,
    totalAmount0: strategySnapshot.totalAmount0 - amount0,
    totalAmount1: strategySnapshot.totalAmount1 - amount1,
    totalFeesCollected0: strategySnapshot.totalFeesCollected0 + feesCollected0,
    totalFeesCollected1: strategySnapshot.totalFeesCollected1 + feesCollected1,
  });
  
  // 8. Create strategy snapshot
  await createStrategySnapshot(strategyId, {
    snapshotType: 'WITHDRAWAL',
    transactionHash: txHash,
    blockNumber,
    // ... current state
  });
}
```

### 4. On Rebalance

```typescript
async function handleRebalance(
  strategyId: string,
  txHash: string,
  blockNumber: bigint
) {
  // 1. Calculate fees for all LPs before rebalance
  const oldSnapshot = await getLatestStrategySnapshot(strategyId);
  await calculateFeesForAllLPs(strategyId, oldSnapshot.id);
  
  // 2. Fetch new position state from contract
  const newPositionState = await fetchPositionStateFromContract(strategyId);
  
  // 3. Create new strategy snapshot
  const newSnapshot = await createStrategySnapshot(strategyId, {
    snapshotType: 'REBALANCE',
    transactionHash: txHash,
    blockNumber,
    tickLowerMain: newPositionState.tickLowerMain,
    tickUpperMain: newPositionState.tickUpperMain,
    tickLowerAlt: newPositionState.tickLowerAlt,
    tickUpperAlt: newPositionState.tickUpperAlt,
    // ... other state
  });
  
  // 4. Recalculate fee snapshots for all LPs with new position ranges
  await calculateFeesForAllLPs(strategyId, newSnapshot.id);
  
  // 5. Update strategy aggregate
  await updateStrategyAggregate(strategyId, {
    lastRebalanceAt: new Date(),
  });
}
```

## Periodic Fee Calculation

Run a cron job to periodically calculate fees for all LPs:

```typescript
async function periodicFeeCalculation(strategyId: string) {
  // 1. Fetch current strategy state from contract
  const currentState = await fetchPositionStateFromContract(strategyId);
  
  // 2. Create strategy snapshot
  const snapshot = await createStrategySnapshot(strategyId, {
    snapshotType: 'MANUAL',
    blockNumber: await getCurrentBlockNumber(),
    // ... current state
  });
  
  // 3. Calculate fees for all active LP positions
  const activePositions = await getActiveLPPositions(strategyId);
  
  for (const position of activePositions) {
    await calculateFeesForLP(position.id, snapshot);
  }
  
  // 4. Update strategy aggregate
  await updateStrategyAggregate(strategyId, {
    lastSnapshotAt: new Date(),
  });
}
```

## Query Examples

### Get user's current position and fees

```typescript
const lpPosition = await prisma.lPPosition.findUnique({
  where: { userId_strategyId: { userId, strategyId } },
  include: {
    feeSnapshots: {
      orderBy: { createdAt: 'desc' },
      take: 1,
    },
  },
});

// Current uncollected fees
const uncollectedFees0 = lpPosition.uncollectedFees0;
const uncollectedFees1 = lpPosition.uncollectedFees1;

// Lifetime earnings
const totalEarnings0 = lpPosition.totalFeesEarned0;
const totalEarnings1 = lpPosition.totalFeesEarned1;
```

### Get fee history for user

```typescript
const feeHistory = await prisma.lPFeeSnapshot.findMany({
  where: { lpPositionId },
  orderBy: { createdAt: 'desc' },
  include: {
    strategySnapshot: {
      select: {
        createdAt: true,
        snapshotType: true,
        priceCurrent: true,
      },
    },
  },
});
```

### Calculate APY for user

```typescript
const thirtyDaysAgo = new Date();
thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30);

const snapshot30d = await prisma.lPFeeSnapshot.findFirst({
  where: {
    lpPositionId,
    createdAt: { lte: thirtyDaysAgo },
  },
  orderBy: { createdAt: 'desc' },
});

const currentSnapshot = await prisma.lPFeeSnapshot.findFirst({
  where: { lpPositionId },
  orderBy: { createdAt: 'desc' },
});

if (snapshot30d && currentSnapshot) {
  const fees30d = BigInt(currentSnapshot.totalFeesEarnedUSD) - 
                  BigInt(snapshot30d.totalFeesEarnedUSD);
  const positionValue = BigInt(snapshot30d.positionValueUSD);
  const apy = (fees30d * 365n * 10000n) / (positionValue * 30n); // Basis points
}
```

## Key Considerations

1. **Precision**: All fee calculations use 128-bit fixed-point math (X128). Need to handle BigInt carefully.

2. **Rebalancing**: When positions rebalance, fee growth values reset. Need to:
   - Capture final fees before rebalance
   - Start new fee tracking with rebalanced positions

3. **Liquidity Share Calculation**: 
   - Shares and liquidity shares should remain proportional
   - On rebalancing, total liquidity may change but user shares stay same
   - Need to recalculate liquidity shares after rebalance

4. **Two Positions**: Strategy has main + alt positions. Calculate weighted average fee growth based on liquidity in each.

5. **Gas Optimization**: 
   - Don't recalculate fees on every block
   - Use periodic snapshots (e.g., every hour)
   - Calculate on-demand for real-time queries

6. **Race Conditions**: 
   - Use transactions for deposit/withdrawal handling
   - Lock strategy aggregate during updates

## Prisma Schema Additions

Add to your `schema.prisma`:

```prisma
// Add relations to existing models
model Strategy {
  // ... existing fields
  lpPositions           LPPosition[]
  strategySnapshots     StrategyPositionSnapshot[]
  strategyAggregate     StrategyAggregate?
  lpDeposits            LPDeposit[]
  lpWithdrawals         LPWithdrawal[]
}

model User {
  // ... existing fields
  lpPositions           LPPosition[]
}

// Add enum
enum SnapshotType {
  DEPOSIT
  WITHDRAWAL
  REBALANCE
  HARVEST
  MANUAL
}

// Then add all the models defined above...
```

This model provides comprehensive tracking of LP positions and accurate fee attribution for each user.

