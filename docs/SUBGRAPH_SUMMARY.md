# Uniswap V3 Subgraph - Quick Reference

## What's Available

### ✅ Position Tracking
- Current liquidity in positions
- Tick ranges (lower/upper)
- Total deposited/withdrawn amounts
- Total collected fees
- Fee growth values (at last update)

### ✅ Event History
- **Mint**: Liquidity added (deposits/rebalances)
- **Burn**: Liquidity removed (withdrawals/rebalances)
- **Collect**: Fees harvested

### ✅ Pool Metrics
- TVL, volume, fees
- Current price and tick
- Global fee growth

### ✅ Historical Data
- Position snapshots (on state changes)
- Daily pool aggregations
- Transaction history

## What's NOT Available (Need Contract)

- ❌ Real-time fee growth (subgraph has indexing delay)
- ❌ Current uncollected fees (need contract query)
- ❌ Position identification (strategy manages positions directly, not via NFT)

## Key Queries

### Get Strategy Positions
```graphql
positions(where: { pool: $poolId, owner: $strategyAddress }) {
  liquidity
  tickLower { tickIdx }
  tickUpper { tickIdx }
  collectedFeesToken0
  collectedFeesToken1
}
```

### Get Recent Events
```graphql
mints(where: { pool: $poolId, owner: $strategyAddress, timestamp_gte: $since })
burns(where: { pool: $poolId, owner: $strategyAddress, timestamp_gte: $since })
collects(where: { pool: $poolId, owner: $strategyAddress, timestamp_gte: $since })
```

## Implementation Notes

1. **Query by owner address**: Strategy contract address = owner of positions
2. **Match tick ranges**: Use tick ranges to identify main vs alt positions
3. **Combine sources**: Use subgraph for events, contract for current state
4. **Sync periodically**: Subgraph indexes with delay, sync every 5-15 min

See `SUBGRAPH_QUERIES.md` for detailed query examples.




