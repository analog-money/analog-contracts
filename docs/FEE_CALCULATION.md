# Fee Calculation for StrategyPassiveManagerUniswap

## Contract Address
**0x58e8fc1f0981d98ba2c52c8ea0f96782e43f84d8** (Base)

## How to Check Fees on Basescan

1. Go to: https://basescan.org/address/0x58e8fc1f0981d98ba2c52c8ea0f96782e43f84d8#readContract

2. In the "Read Contract" tab, try these functions:
   - `getStratFeeId()` - Get the fee configuration ID
   - `depositFee()` - Should return 0 (always 0 per contract)
   - `withdrawFee()` - Should return 0 (always 0 per contract)
   - `factory()` - Get factory address (to find fee config)
   - `beefyFeeConfig()` - May not be directly callable, need factory first

3. Once you have the factory address, query the factory contract:
   - `beefyFeeConfig()` - Returns the IFeeConfig contract address

4. Query the IFeeConfig contract with the strategy address:
   - `getFees(address strategy)` - Returns FeeCategory with:
     - `total` - Total fee percentage (in wei, 1e18 = 100%)
     - `beefy` - Beefy fee percentage
     - `call` - Call fee (harvester) percentage  
     - `strategist` - Strategist fee percentage
     - `label` - Fee tier label
     - `active` - Whether active

## Fee Calculation Formula

Based on the contract code (`_chargeFees` function):

```solidity
// From StrategyPassiveManagerUniswap.sol lines 404-449
function _chargeFees(address _callFeeRecipient, uint256 _amount0, uint256 _amount1) 
    private returns (uint256 _amountLeft0, uint256 _amountLeft1) {
    
    IFeeConfig.FeeCategory memory fees = getFees();
    
    // Calculate fee amounts
    uint256 amountToSwap0 = _amount0 * fees.total / DIVISOR;  // DIVISOR = 1e18
    uint256 amountToSwap1 = _amount1 * fees.total / DIVISOR;
    
    // ... swap to native and distribute ...
}
```

### Percentage Calculation

```
fee_percentage = (fees.total / 1e18) * 100

Example:
- If fees.total = 450000000000000000 (0.45 * 1e18)
- Percentage = (450000000000000000 / 1000000000000000000) * 100 = 4.5%
```

## What This Means

- **Fees are charged on EARNED YIELD/FEES**, not on principal
- When `harvest()` is called:
  1. Fees are claimed from Uniswap positions (`_claimEarnings()`)
  2. Liquidity is removed
  3. **Fees are charged** (`_chargeFees()`)
     - `fees.total` percentage of earned fees is taken
     - Swapped to native token
     - Distributed to: Beefy, Call Fee Recipient, Strategist
  4. Remaining tokens are re-added to liquidity

## Distribution of Charged Fees

Once fees are collected (as native token), they're distributed as:
- **Call Fee**: `nativeEarned * fees.call / DIVISOR` → Goes to harvester
- **Strategist Fee**: `nativeEarned * fees.strategist / DIVISOR` → Goes to strategist
- **Beefy Fee**: Remaining amount → Goes to Beefy treasury

## Example Calculation

If the strategy earns **$1,000 in fees** from Uniswap:

**Scenario 1: 4.5% Total Fee**
- Users receive: $955.00 (95.5%)
- Protocol takes: $45.00 (4.5%)
  - Beefy: ~$30.00 (if 2.5% of total)
  - Call Fee: ~$10.00 (if 1% of total)
  - Strategist: ~$5.00 (if 0.5% of total)

**Scenario 2: 0% Total Fee (Zero Fees)**
- Users receive: $1,000.00 (100%)
- Protocol takes: $0.00 (0%)

## To Get Actual Values

Run the script:
```bash
cd apps/contracts2
node check-fees.js
```

Or manually check on Basescan:
1. Contract: https://basescan.org/address/0x58e8fc1f0981d98ba2c52c8ea0f96782e43f84d8
2. Read Contract tab → `getStratFeeId()` → Note the fee ID
3. Find the factory contract → `beefyFeeConfig()` → Get fee config address
4. Query fee config with strategy address → `getFees(0x58e8fc1f0981d98ba2c52c8ea0f96782e43f84d8)`

## Important Notes

- **Deposit/Withdraw fees are ALWAYS 0** (hardcoded in contract)
- Fees are only charged on **performance/yield earned**
- Fees are charged during `harvest()` calls
- The fee percentage is configurable via the IFeeConfig contract
- To set zero fees, configure `fees.total = 0` in the fee config



