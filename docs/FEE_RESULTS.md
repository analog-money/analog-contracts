# Fee Analysis Results for StrategyPassiveManagerUniswap

## Contract Addresses
- **Proxy**: `0xbB8815Fa8006EA1c343DdB30962811a78ab5529d`
- **Implementation**: `0x58e8fc1f0981d98ba2c52c8ea0f96782e43f84d8`

## Fee Configuration (from getAllFees() response)

### Performance Fees (Charged on Yield Earned)
- **Total Fee**: `95000000000000000` wei = **9.5%** of yield
- **Beefy Fee**: `946315789473684211` wei = **94.6316%** of total fees (≈9.0% of yield)
- **Call Fee**: `1052631578947368` wei = **0.1053%** of total fees (≈0.01% of yield)
- **Strategist Fee**: `52631578947368421` wei = **5.2632%** of total fees (≈0.5% of yield)

### Deposit/Withdraw Fees
- **Deposit Fee**: `0` = **0%**
- **Withdraw Fee**: `0` = **0%**

### Label & Status
- **Label**: `default`
- **Active**: `true`

## Fee Distribution Breakdown

The individual fees (beefy, call, strategist) are percentages **of the total fee amount**, not of yield:

- **Beefy**: 94.6316% of the 9.5% total = **~9.0% of yield**
- **Call Fee**: 0.1053% of the 9.5% total = **~0.01% of yield**
- **Strategist**: 5.2632% of the 9.5% total = **~0.5% of yield**

Verification: 94.6316% + 0.1053% + 5.2632% = 100% ✅

## Calculation Examples

### Example 1: $1,000 Yield Earned
- **Total fee taken**: $1,000 × 9.5% = **$95.00**
- **Users receive**: $1,000 - $95 = **$905.00 (90.5%)**
- **Protocol receives**: **$95.00 (9.5%)**
  - Beefy: $95 × 94.63% = **$89.90**
  - Call Fee (harvester): $95 × 0.11% = **$0.10**
  - Strategist: $95 × 5.26% = **$5.00**

### Example 2: $10,000 Yield Earned
- **Total fee taken**: $10,000 × 9.5% = **$950.00**
- **Users receive**: $10,000 - $950 = **$9,050.00 (90.5%)**
- **Protocol receives**: **$950.00 (9.5%)**
  - Beefy: $950 × 94.63% = **$898.99**
  - Call Fee (harvester): $950 × 0.11% = **$1.05**
  - Strategist: $950 × 5.26% = **$49.96**

## Summary

**🎯 Percentage of yield charged to users: 9.5%**

- Users keep: **90.5%** of earned yield
- Protocol takes: **9.5%** of earned yield
  - Beefy Finance: ~9.0% of yield
  - Strategist: ~0.5% of yield
  - Harvester (call fee): ~0.01% of yield

## Important Notes

1. Fees are **only charged on yield/fees earned** from Uniswap positions
2. Fees are **NOT charged** on deposits or withdrawals (both are 0%)
3. Fees are collected during `harvest()` calls
4. The 9.5% is a standard Beefy Finance performance fee tier


