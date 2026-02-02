# Fee Structure in StrategyPassiveManagerUniswap

## How Fees Are Calculated

The contract charges fees on **earned fees** (not on deposits/withdrawals). Fees are taken during the `harvest()` function.

### Fee Configuration

Fees are fetched from an external `IFeeConfig` contract:

```solidity
IFeeConfig.FeeCategory memory fees = getFees();
```

The fee structure includes:
- `fees.total` - Total percentage of fees charged (in wei, where 1e18 = 100%)
- `fees.call` - Percentage to harvester/caller
- `fees.strategist` - Percentage to strategist
- `fees.beefy` - Percentage to Beefy (calculated as remaining)

### Fee Calculation (from `_chargeFees` function)

```solidity
// Line 412: Calculate fee amount for token0
uint256 amountToSwap0 = _amount0 * fees.total / DIVISOR;

// Line 426: Calculate fee amount for token1  
uint256 amountToSwap1 = _amount1 * fees.total / DIVISOR;
```

Where `DIVISOR = 1 ether = 1e18` (defined in `StratFeeManagerInitializable.sol` line 49)

### Percentage Calculation

**The percentage taken from users = `(fees.total / 1e18) * 100%`**

Examples:
- `fees.total = 0` → **0% fees** (zero fees)
- `fees.total = 1e16` (0.01 * 1e18) → **1% fees**
- `fees.total = 1e17` (0.1 * 1e18) → **10% fees**
- `fees.total = 1e18` (1.0 * 1e18) → **100% fees** (all fees taken)

### Fee Distribution

After calculating the total fee amount, it's distributed to:
1. **Call Fee**: `nativeEarned * fees.call / DIVISOR` → Goes to harvester
2. **Strategist Fee**: `nativeEarned * fees.strategist / DIVISOR` → Goes to strategist
3. **Beefy Fee**: `nativeEarned - callFeeAmount - strategistFeeAmount` → Goes to Beefy

### Important Notes

1. **Fees are only on earned yield**, not on deposits or withdrawals
2. **Deposit and withdraw fees are hardcoded to 0** (from StratFeeManagerInitializable)
3. **Fees are configurable** via the `IFeeConfig` contract
4. **To charge zero fees**, set `fees.total = 0` in the fee config

### How Fees Are Charged

During `harvest()`:
1. Uniswap fees are claimed from positions (`_claimEarnings()`)
2. Liquidity is removed (`_removeLiquidity()`)
3. **Fees are charged** (`_chargeFees()`):
   - Calculates `amountToSwap = fees * fees.total / DIVISOR`
   - Swaps fee amount to native token
   - Distributes to call/strategist/beefy recipients
4. Remaining tokens are re-added to positions (`_addLiquidity()`)

## To Achieve Zero Fees

Set the fee configuration to:
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

Then set this fee config ID on the strategy:
```solidity
strategy.setStratFeeId(zeroFeeConfigId);
```

With `fees.total = 0`, no tokens are swapped and all earned fees remain in the strategy for users.



