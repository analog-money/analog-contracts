# Abstracted LP Tracking Data Model

This document defines a generic, abstracted data model for tracking LP positions across different DEX types (Uniswap V3, Aerodrome, etc.) with comprehensive price tracking for impermanent loss calculations.

## Design Principles

1. **DEX-Agnostic**: Works for Uniswap V3, Aerodrome, and future DEX integrations
2. **Price Tracking**: Tracks all token prices needed for IL calculations
3. **Flexible**: Supports different liquidity models (concentrated, constant product, etc.)
4. **Comprehensive**: Captures all data needed for backtesting, fee tracking, and IL calculations

## Core Models

### 1. Token & Price Tracking

```prisma
// Track all tokens used in any LP position
model Token {
  id              String   @id @default(cuid())
  address         String   @unique
  chainId         Int
  symbol          String
  name            String?
  decimals        Int
  logoURI         String?
  
  // Price tracking (one-to-many)
  prices          TokenPrice[]
  
  // LP positions using this token
  token0Positions LPPosition[] @relation("Token0")
  token1Positions LPPosition[] @relation("Token1")
  
  createdAt       DateTime @default(now())
  updatedAt       DateTime @updatedAt
  
  @@index([address, chainId])
  @@index([symbol])
}

// Historical price tracking for all tokens
model TokenPrice {
  id        String   @id @default(cuid())
  tokenId   String
  priceUSD  Decimal  @db.Decimal(18, 8)
  timestamp DateTime @default(now())
  source    String   @default("coingecko") // coingecko, uniswap, aerodrome, etc.
  
  token     Token    @relation(fields: [tokenId], references: [id], onDelete: Cascade)
  
  @@unique([tokenId, timestamp, source])
  @@index([tokenId, timestamp])
  @@index([timestamp])
}

// Price snapshot at specific points in time (for IL calculations)
model TokenPriceSnapshot {
  id              String   @id @default(cuid())
  token0Id        String
  token1Id        String
  price0USD       Decimal  @db.Decimal(18, 8)
  price1USD       Decimal  @db.Decimal(18, 8)
  priceRatio      Decimal  @db.Decimal(18, 8) // token0/token1
  timestamp       DateTime @default(now())
  
  token0          Token    @relation("PriceSnapshotToken0", fields: [token0Id], references: [id])
  token1          Token    @relation("PriceSnapshotToken1", fields: [token1Id], references: [id])
  
  // Link to LP snapshots
  lpSnapshots     LPSnapshot[]
  
  @@unique([token0Id, token1Id, timestamp])
  @@index([token0Id, token1Id, timestamp])
  @@index([timestamp])
}
```

### 2. DEX Configuration

```prisma
// DEX type definition
enum DEXType {
  UNISWAP_V3
  AERODROME
  VELODROME
  // Add more as needed
}

// DEX-specific configuration
model DEX {
  id              String    @id @default(cuid())
  type            DEXType
  name            String
  chainId         Int
  factoryAddress  String?
  routerAddress   String?
  
  // DEX-specific settings
  settings        Json?     // Flexible JSON for DEX-specific config
  
  // Pools on this DEX
  pools           Pool[]
  
  createdAt       DateTime  @default(now())
  updatedAt       DateTime  @updatedAt
  
  @@unique([type, chainId])
  @@index([type])
}
```

### 3. Pool (Generic)

```prisma
// Generic pool model (works for any DEX)
model Pool {
  id              String   @id @default(cuid())
  dexId           String
  address         String   @unique
  token0Id        String
  token1Id        String
  fee             Int      // Fee tier (e.g., 500 = 0.05%)
  
  // DEX-specific pool data (flexible JSON)
  // For Uniswap V3: { tickSpacing, sqrtPrice, liquidity, etc. }
  // For Aerodrome: { similar fields }
  poolData        Json?
  
  // Strategy positions in this pool
  strategies      Strategy[]
  
  dex             DEX      @relation(fields: [dexId], references: [id])
  token0          Token    @relation("PoolToken0", fields: [token0Id], references: [id])
  token1          Token    @relation("PoolToken1", fields: [token1Id], references: [id])
  
  createdAt       DateTime @default(now())
  updatedAt       DateTime @updatedAt
  
  @@index([dexId])
  @@index([token0Id, token1Id])
  @@index([address])
}
```

### 4. Strategy (Abstracted)

```prisma
// Strategy managing LP positions
model Strategy {
  id                String   @id @default(cuid())
  name              String
  address           String   @unique
  poolId            String
  chainId           Int
  
  // Strategy type configuration (flexible JSON)
  // For Uniswap V3: { positionMain, positionAlt, tickLower, tickUpper, etc. }
  // For Aerodrome: { similar structure }
  strategyConfig    Json?
  
  // Aggregate tracking
  aggregate         StrategyAggregate?
  
  // User positions
  lpPositions       LPPosition[]
  
  // Historical snapshots
  snapshots         StrategySnapshot[]
  
  // Events
  deposits          LPDeposit[]
  withdrawals       LPWithdrawal[]
  
  pool              Pool     @relation(fields: [poolId], references: [id])
  
  createdAt         DateTime @default(now())
  updatedAt         DateTime @updatedAt
  
  @@index([poolId])
  @@index([address])
}
```

### 5. LP Position (Generic)

```prisma
// Generic LP position - works for any DEX type
model LPPosition {
  id                    String   @id @default(cuid())
  userId                String
  strategyId            String
  token0Id              String
  token1Id              String
  
  // Position state (token-agnostic)
  shares                String   @default("0") // Total shares owned
  liquidityShare        String   @default("0") // Current liquidity share
  
  // Token amounts at last snapshot
  amount0               String   @default("0")
  amount1               String   @default("0")
  
  // USD values (calculated)
  amount0USD            String   @default("0")
  amount1USD            String   @default("0")
  totalValueUSD         String   @default("0")
  
  // Fee tracking (token-agnostic)
  lastFeeGrowth0        String   @default("0") // DEX-specific fee growth format
  lastFeeGrowth1        String   @default("0")
  uncollectedFees0      String   @default("0")
  uncollectedFees1      String   @default("0")
  
  // Historical totals
  totalFeesEarned0      String   @default("0")
  totalFeesEarned1      String   @default("0")
  totalFeesEarnedUSD    String   @default("0")
  
  // IL tracking
  initialDepositValueUSD String  @default("0") // Value at deposit
  currentValueUSD       String   @default("0") // Current position value
  impermanentLossUSD    String   @default("0") // IL = currentValue - (holdValue)
  holdValueUSD          String   @default("0") // Value if held tokens
  
  // Timestamps
  createdAt             DateTime @default(now())
  updatedAt             DateTime @updatedAt
  lastSnapshotAt        DateTime @default(now())
  
  // Relations
  user                  User     @relation(fields: [userId], references: [id])
  strategy              Strategy @relation(fields: [strategyId], references: [id])
  token0                Token    @relation("Token0", fields: [token0Id], references: [id])
  token1                Token    @relation("Token1", fields: [token1Id], references: [id])
  
  deposits              LPDeposit[]
  withdrawals           LPWithdrawal[]
  snapshots             LPSnapshot[]
  
  @@unique([userId, strategyId])
  @@index([userId])
  @@index([strategyId])
  @@index([lastSnapshotAt])
}
```

### 6. Strategy Snapshot (Generic)

```prisma
enum SnapshotType {
  DEPOSIT
  WITHDRAWAL
  REBALANCE
  HARVEST
  MANUAL
}

// Generic strategy snapshot - DEX-agnostic
model StrategySnapshot {
  id                    String    @id @default(cuid())
  strategyId            String
  
  // Pool state at snapshot
  poolAddress           String
  currentPrice          String?   // Current price (format depends on DEX)
  
  // Position state (flexible - depends on DEX)
  // For Uniswap V3: { tickLower, tickUpper, liquidity, sqrtPrice, etc. }
  // For Aerodrome: { similar structure }
  positionData          Json
  
  // Aggregated liquidity
  totalLiquidity        String
  totalAmount0          String
  totalAmount1          String
  
  // Fee tracking
  feeGrowth0            String
  feeGrowth1            String
  uncollectedFees0      String
  uncollectedFees1      String
  
  // Price snapshot at this point
  priceSnapshotId       String?
  
  // Value calculations
  positionValueUSD      String
  
  // Snapshot metadata
  blockNumber           BigInt
  transactionHash       String?
  snapshotType          SnapshotType
  createdAt             DateTime  @default(now())
  
  // Relations
  strategy              Strategy  @relation(fields: [strategyId], references: [id])
  priceSnapshot         TokenPriceSnapshot? @relation(fields: [priceSnapshotId], references: [id])
  lpSnapshots           LPSnapshot[]
  
  @@index([strategyId])
  @@index([blockNumber])
  @@index([createdAt])
  @@index([snapshotType])
}
```

### 7. LP Snapshot (With IL Tracking)

```prisma
// LP position snapshot with IL calculations
model LPSnapshot {
  id                    String    @id @default(cuid())
  lpPositionId          String
  strategySnapshotId    String
  priceSnapshotId       String
  
  // Position state
  shares                String
  liquidityShare        String
  liquiditySharePercent Float
  
  // Token amounts
  amount0               String
  amount1               String
  amount0USD            String
  amount1USD            String
  totalValueUSD         String
  
  // Fee calculations
  feeGrowth0            String
  feeGrowth1            String
  feesAccrued0          String
  feesAccrued1          String
  feesAccruedUSD        String
  
  // Cumulative totals
  totalFeesEarned0      String
  totalFeesEarned1      String
  totalFeesEarnedUSD    String
  
  // Impermanent Loss calculations
  // Reference prices at deposit
  depositPrice0USD      String   // Price of token0 at deposit
  depositPrice1USD      String   // Price of token1 at deposit
  depositValueUSD       String   // Total value at deposit
  
  // Current prices (from price snapshot)
  currentPrice0USD      String
  currentPrice1USD      String
  currentValueUSD       String
  
  // Hold value = what value would be if held tokens
  holdValueUSD          String
  
  // IL calculations
  impermanentLossUSD    String   // IL = currentValue - holdValue
  impermanentLossPercent Float?  // IL% = (currentValue - holdValue) / holdValue * 100
  
  // Net return = fees - IL
  netReturnUSD          String   // fees - IL
  netReturnPercent      Float?   // netReturn / depositValue * 100
  
  createdAt             DateTime  @default(now())
  
  // Relations
  lpPosition            LPPosition @relation(fields: [lpPositionId], references: [id])
  strategySnapshot      StrategySnapshot @relation(fields: [strategySnapshotId], references: [id])
  priceSnapshot         TokenPriceSnapshot @relation(fields: [priceSnapshotId], references: [id])
  
  @@index([lpPositionId])
  @@index([strategySnapshotId])
  @@index([createdAt])
}
```

### 8. Deposit/Withdrawal Events

```prisma
// Generic deposit event
model LPDeposit {
  id                    String    @id @default(cuid())
  lpPositionId          String
  strategyId            String
  
  // Deposit amounts
  amount0               String
  amount1               String
  sharesMinted          String
  
  // Price snapshot at deposit (for IL tracking)
  priceSnapshotId       String?
  depositValueUSD       String
  
  // Position state at deposit
  liquidityBefore       String
  liquidityAfter        String
  liquidityShareBefore  String
  liquidityShareAfter   String
  
  // Fee state
  feeGrowth0            String
  feeGrowth1            String
  
  // Transaction details
  transactionHash       String    @unique
  blockNumber           BigInt
  blockTimestamp        DateTime
  
  // Relations
  lpPosition            LPPosition @relation(fields: [lpPositionId], references: [id])
  strategy              Strategy   @relation(fields: [strategyId], references: [id])
  priceSnapshot         TokenPriceSnapshot? @relation("DepositPriceSnapshot", fields: [priceSnapshotId], references: [id])
  
  @@index([lpPositionId])
  @@index([strategyId])
  @@index([blockNumber])
  @@index([blockTimestamp])
}

// Generic withdrawal event
model LPWithdrawal {
  id                    String    @id @default(cuid())
  lpPositionId          String
  strategyId            String
  
  // Withdrawal amounts
  sharesBurned          String
  amount0               String
  amount1               String
  
  // Price snapshot at withdrawal
  priceSnapshotId       String?
  withdrawalValueUSD    String
  
  // Position state
  liquidityBefore       String
  liquidityAfter        String
  liquidityShareBefore  String
  liquidityShareAfter   String
  
  // Fee state
  feeGrowth0            String
  feeGrowth1            String
  feesCollected0        String
  feesCollected1        String
  feesCollectedUSD      String
  
  // Transaction details
  transactionHash       String    @unique
  blockNumber           BigInt
  blockTimestamp        DateTime
  
  // Relations
  lpPosition            LPPosition @relation(fields: [lpPositionId], references: [id])
  strategy              Strategy   @relation(fields: [strategyId], references: [id])
  priceSnapshot         TokenPriceSnapshot? @relation("WithdrawalPriceSnapshot", fields: [priceSnapshotId], references: [id])
  
  @@index([lpPositionId])
  @@index([strategyId])
  @@index([blockNumber])
  @@index([blockTimestamp])
}
```

### 9. Strategy Aggregate

```prisma
// High-level strategy tracking
model StrategyAggregate {
  id                    String    @id @default(cuid())
  strategyId            String    @unique
  
  // Current aggregated state
  totalShares           String    @default("0")
  totalLiquidity        String    @default("0")
  totalAmount0          String    @default("0")
  totalAmount1          String    @default("0")
  
  // Current fee state
  feeGrowth0            String    @default("0")
  feeGrowth1            String    @default("0")
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

## Price Tracking Strategy

### Track Prices for All Tokens

```typescript
// Service to track token prices
class TokenPriceService {
  /**
   * Track price for a token at a specific time
   */
  async recordTokenPrice(
    tokenAddress: string,
    chainId: number,
    priceUSD: number,
    timestamp: Date,
    source: string = "coingecko"
  ) {
    // Get or create token
    const token = await prisma.token.upsert({
      where: { address_chainId: { address: tokenAddress, chainId } },
      update: {},
      create: {
        address: tokenAddress,
        chainId,
        symbol: await fetchTokenSymbol(tokenAddress, chainId),
        decimals: await fetchTokenDecimals(tokenAddress, chainId),
      },
    });
    
    // Record price
    await prisma.tokenPrice.upsert({
      where: {
        tokenId_timestamp_source: {
          tokenId: token.id,
          timestamp,
          source,
        },
      },
      update: { priceUSD },
      create: {
        tokenId: token.id,
        priceUSD,
        timestamp,
        source,
      },
    });
  }
  
  /**
   * Create price snapshot for a token pair
   */
  async createPriceSnapshot(
    token0Address: string,
    token1Address: string,
    chainId: number,
    timestamp: Date
  ) {
    const [token0, token1] = await Promise.all([
      prisma.token.findUnique({ where: { address_chainId: { address: token0Address, chainId } } }),
      prisma.token.findUnique({ where: { address_chainId: { address: token1Address, chainId } } }),
    ]);
    
    if (!token0 || !token1) throw new Error("Tokens not found");
    
    // Get prices at timestamp
    const [price0, price1] = await Promise.all([
      this.getPriceAtTime(token0.id, timestamp),
      this.getPriceAtTime(token1.id, timestamp),
    ]);
    
    if (!price0 || !price1) throw new Error("Prices not available");
    
    const priceRatio = price0 / price1;
    
    return prisma.tokenPriceSnapshot.create({
      data: {
        token0Id: token0.id,
        token1Id: token1.id,
        price0USD: price0,
        price1USD: price1,
        priceRatio,
        timestamp,
      },
    });
  }
  
  /**
   * Get token price at specific time (with interpolation if needed)
   */
  async getPriceAtTime(tokenId: string, timestamp: Date): Promise<number | null> {
    // Find closest price records before and after
    const [before, after] = await Promise.all([
      prisma.tokenPrice.findFirst({
        where: {
          tokenId,
          timestamp: { lte: timestamp },
        },
        orderBy: { timestamp: "desc" },
      }),
      prisma.tokenPrice.findFirst({
        where: {
          tokenId,
          timestamp: { gte: timestamp },
        },
        orderBy: { timestamp: "asc" },
      }),
    ]);
    
    if (!before) return null;
    if (!after) return before.priceUSD.toNumber();
    
    // Interpolate if both exist
    const timeDiff = after.timestamp.getTime() - before.timestamp.getTime();
    const beforeDiff = timestamp.getTime() - before.timestamp.getTime();
    const ratio = beforeDiff / timeDiff;
    
    return (
      before.priceUSD.toNumber() * (1 - ratio) +
      after.priceUSD.toNumber() * ratio
    );
  }
}
```

## Impermanent Loss Calculation

```typescript
class ILCalculationService {
  /**
   * Calculate IL for an LP position
   */
  async calculateIL(
    lpPositionId: string,
    currentSnapshotId: string
  ) {
    const lpPosition = await prisma.lPPosition.findUnique({
      where: { id: lpPositionId },
      include: {
        deposits: {
          orderBy: { blockTimestamp: "asc" },
          include: { priceSnapshot: true },
        },
        snapshots: {
          where: { id: currentSnapshotId },
          include: { priceSnapshot: true },
        },
      },
    });
    
    if (!lpPosition || !lpPosition.snapshots.length) return null;
    
    const currentSnapshot = lpPosition.snapshots[0];
    const priceSnapshot = currentSnapshot.priceSnapshot;
    
    // Get deposit price (weighted average if multiple deposits)
    const totalDepositValue = lpPosition.deposits.reduce(
      (sum, deposit) => sum + parseFloat(deposit.depositValueUSD),
      0
    );
    
    const weightedPrice0 = lpPosition.deposits.reduce((sum, deposit) => {
      const weight = parseFloat(deposit.depositValueUSD) / totalDepositValue;
      return sum + parseFloat(deposit.priceSnapshot.price0USD) * weight;
    }, 0);
    
    const weightedPrice1 = lpPosition.deposits.reduce((sum, deposit) => {
      const weight = parseFloat(deposit.depositValueUSD) / totalDepositValue;
      return sum + parseFloat(deposit.priceSnapshot.price1USD) * weight;
    }, 0);
    
    // Current prices
    const currentPrice0 = parseFloat(priceSnapshot.price0USD);
    const currentPrice1 = parseFloat(priceSnapshot.price1USD);
    
    // Current position value (from snapshot)
    const currentValue = parseFloat(currentSnapshot.totalValueUSD);
    
    // Hold value = what tokens would be worth if held
    const token0Amount = parseFloat(lpPosition.amount0);
    const token1Amount = parseFloat(lpPosition.amount1);
    const holdValue = token0Amount * currentPrice0 + token1Amount * currentPrice1;
    
    // IL = currentValue - holdValue
    const ilUSD = currentValue - holdValue;
    const ilPercent = (ilUSD / holdValue) * 100;
    
    // Net return = fees - IL
    const totalFeesUSD = parseFloat(lpPosition.totalFeesEarnedUSD);
    const netReturn = totalFeesUSD + ilUSD; // IL is negative, so fees offset it
    const netReturnPercent = (netReturn / totalDepositValue) * 100;
    
    // Update snapshot with IL calculations
    await prisma.lPSnapshot.update({
      where: { id: currentSnapshotId },
      data: {
        depositPrice0USD: weightedPrice0.toString(),
        depositPrice1USD: weightedPrice1.toString(),
        depositValueUSD: totalDepositValue.toString(),
        currentPrice0USD: currentPrice0.toString(),
        currentPrice1USD: currentPrice1.toString(),
        currentValueUSD: currentValue.toString(),
        holdValueUSD: holdValue.toString(),
        impermanentLossUSD: ilUSD.toString(),
        impermanentLossPercent: ilPercent,
        netReturnUSD: netReturn.toString(),
        netReturnPercent,
      },
    });
    
    // Update LP position
    await prisma.lPPosition.update({
      where: { id: lpPositionId },
      data: {
        initialDepositValueUSD: totalDepositValue.toString(),
        currentValueUSD: currentValue.toString(),
        holdValueUSD: holdValue.toString(),
        impermanentLossUSD: ilUSD.toString(),
      },
    });
    
    return {
      ilUSD,
      ilPercent,
      netReturnUSD: netReturn,
      netReturnPercent,
      feesUSD: totalFeesUSD,
    };
  }
}
```

## Benefits of This Model

1. **DEX-Agnostic**: Works for Uniswap V3, Aerodrome, and future DEXs
2. **Comprehensive Price Tracking**: All tokens tracked with historical prices
3. **IL Calculations**: Built-in IL tracking for all positions
4. **Flexible**: JSON fields for DEX-specific data
5. **Complete History**: Full audit trail of all events and snapshots
6. **Efficient Queries**: Proper indexes for fast lookups
7. **Scalable**: Can handle multiple strategies, users, and tokens

## Migration from Existing Models

To migrate existing `UniswapVault` data:

```typescript
async function migrateUniswapVaults() {
  const vaults = await prisma.uniswapVault.findMany({
    include: { vault: true },
  });
  
  for (const vault of vaults) {
    // Create or get DEX
    const dex = await prisma.dEX.upsert({
      where: { type_chainId: { type: "UNISWAP_V3", chainId: 8453 } },
      update: {},
      create: {
        type: "UNISWAP_V3",
        name: "Uniswap V3",
        chainId: 8453,
      },
    });
    
    // Create or get tokens
    const [token0, token1] = await Promise.all([
      getOrCreateToken(vault.token0Address, 8453),
      getOrCreateToken(vault.token1Address, 8453),
    ]);
    
    // Create pool
    const pool = await prisma.pool.create({
      data: {
        dexId: dex.id,
        address: vault.poolAddress,
        token0Id: token0.id,
        token1Id: token1.id,
        fee: vault.fee,
        poolData: {
          tickSpacing: vault.tickSpacing,
          sqrtPrice: vault.sqrtPriceX96,
          liquidity: vault.poolLiquidity,
        },
      },
    });
    
    // Create strategy
    const strategy = await prisma.strategy.create({
      data: {
        name: vault.vault.name,
        address: vault.vault.vaultAddress,
        poolId: pool.id,
        chainId: 8453,
        strategyConfig: {
          tickLower: vault.tickLower,
          tickUpper: vault.tickUpper,
          positionMain: { tickLower: vault.tickLower, tickUpper: vault.tickUpper },
        },
      },
    });
    
    // Migrate history...
  }
}
```

This abstracted model provides a solid foundation for tracking LP positions across different DEXs with comprehensive price tracking for IL calculations.



