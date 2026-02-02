# AnalogVault Implementation Deployment & Upgrade Guide

## Overview

This guide explains how to deploy a new AnalogVault implementation (with two-step withdrawal) and update the factory to use it.

---

## Prerequisites

1. **Environment Variables**:
   ```bash
   export BASE_HTTP_RPC_URL="https://mainnet.base.org" # or your RPC URL
   export PRIVATE_KEY="0x..."  # Deployer private key (must be factory owner)
   export FACTORY_ADDRESS="0x..." # AnalogVaultFactory address
   ```

2. **Permissions**: The deployer account must be the owner of the AnalogVaultFactory

3. **Verify Contract Source**: Ensure `AnalogVault.sol` has all changes you want to deploy

---

## Deployment Steps

### Step 1: Dry Run (Simulation)

Test the deployment without broadcasting:

```bash
cd apps/contracts2

forge script script/DeployAnalogVaultImplementation.s.sol:DeployAnalogVaultImplementation \
  --rpc-url $BASE_HTTP_RPC_URL \
  -vvv
```

**What this does:**
- Simulates the deployment
- Shows gas estimates
- Previews which vaults need upgrading
- No on-chain transactions

### Step 2: Deploy to Testnet (Optional but Recommended)

Deploy to Base Sepolia first:

```bash
export BASE_SEPOLIA_RPC_URL="https://sepolia.base.org"
export FACTORY_ADDRESS="0x..." # Testnet factory address

forge script script/DeployAnalogVaultImplementation.s.sol:DeployAnalogVaultImplementation \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  -vvv
```

### Step 3: Deploy to Mainnet

Deploy the new implementation and update factory:

```bash
export FACTORY_ADDRESS="0x..." # Mainnet factory address

forge script script/DeployAnalogVaultImplementation.s.sol:DeployAnalogVaultImplementation \
  --rpc-url $BASE_HTTP_RPC_URL \
  --broadcast \
  --verify \
  -vvv
```

**What this does:**
1. Deploys new AnalogVault implementation
2. Calls `factory.setLatestImplementation(newImplementation)`
3. Verifies contract on Basescan
4. Lists vaults that need upgrading

---

## Post-Deployment

### 1. Verify Deployment

Check the factory's latest implementation:

```bash
cast call $FACTORY_ADDRESS "latestImplementation()" --rpc-url $BASE_HTTP_RPC_URL
```

Should return the new implementation address.

### 2. Check Vaults Needing Upgrade

```bash
cast call $FACTORY_ADDRESS "getVaultsNeedingUpgrade()" --rpc-url $BASE_HTTP_RPC_URL
```

Returns array of vault addresses that haven't upgraded yet.

### 3. Upgrade Existing Vaults

**Option A: User Self-Upgrade**

Each vault owner can upgrade their own vault:

```solidity
// As vault owner
vault.upgradeToLatest();
```

**Option B: Notify Users**

Send notification to vault owners to upgrade:
- Email/notification with upgrade instructions
- Dashboard showing "Upgrade Available"
- Link to transaction to call `upgradeToLatest()`

### 4. Verify Vault Upgrade

Check a vault's implementation:

```bash
# Get implementation storage slot
cast storage $VAULT_ADDRESS \
  0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc \
  --rpc-url $BASE_HTTP_RPC_URL
```

Should match the new implementation address.

---

## Two-Step Withdrawal Functions

After upgrade, vaults will have these new functions:

### Step 1: withdrawFromStrategy
```solidity
function withdrawFromStrategy(
    uint256 amount0,      // 0 = withdraw all
    uint256 amount1,      // 0 = withdraw all  
    uint256 minAmount0,   // Slippage protection
    uint256 minAmount1    // Slippage protection
) external onlyVaultOwner
```

### Step 2: swapAndSendToUser
```solidity
function swapAndSendToUser(
    SwapCall[] calldata swapCalls,  // 1inch swap data
    address recipient                 // USDC recipient
) external onlyVaultOwner
```

### State Variables
```solidity
uint256 public pendingWithdrawAmount0;
uint256 public pendingWithdrawAmount1;
```

---

## Rollback Plan

If issues are found, you can deploy and set a previous/fixed implementation:

```bash
# Deploy fixed implementation
forge create src/AnalogVault.sol:AnalogVault \
  --rpc-url $BASE_HTTP_RPC_URL \
  --private-key $PRIVATE_KEY

# Update factory
cast send $FACTORY_ADDRESS \
  "setLatestImplementation(address)" \
  $NEW_IMPLEMENTATION_ADDRESS \
  --rpc-url $BASE_HTTP_RPC_URL \
  --private-key $PRIVATE_KEY
```

---

## Testing

### Local Fork Test

Test upgrade on a local fork:

```bash
forge test --match-contract AnalogVaultTwoStepWithdrawForkTest \
  --fork-url $BASE_HTTP_RPC_URL \
  -vvv
```

### Manual Testing Steps

1. **Deploy to testnet**
2. **Create test vault** using factory
3. **Deposit funds** to vault
4. **Execute swaps and deposit** to strategy
5. **Test Step 1**: Call `withdrawFromStrategy()`
6. **Verify pending amounts**: Read `pendingWithdrawAmount0/1`
7. **Test Step 2**: Call `swapAndSendToUser()`
8. **Verify results**: Check USDC received by recipient

---

## Troubleshooting

### "Only owner can call this function"
- Ensure deployer is factory owner
- Check with: `cast call $FACTORY_ADDRESS "owner()"`

### "Invalid implementation"
- Implementation address cannot be zero
- Implementation must be a valid contract

### Vault upgrade fails
- Check vault owner is caller
- Verify factory has correct latest implementation
- Ensure implementation is different from current

### Gas estimation failed
- Check RPC URL is correct
- Verify account has enough ETH for gas
- Try increasing gas limit

---

## Security Checklist

Before deploying to mainnet:

- [ ] Code reviewed by team
- [ ] All tests passing
- [ ] Deployed and tested on testnet
- [ ] Contract verified on Basescan
- [ ] Factory owner confirmed
- [ ] Rollback plan documented
- [ ] User notification plan ready
- [ ] Monitor tools set up (e.g., Tenderly)

---

## Monitoring

After deployment, monitor:

1. **Factory events**:
   - `ImplementationUpdated`
   
2. **Vault upgrades**:
   - Count of vaults upgraded
   - Gas costs
   - Any failures

3. **Two-step withdrawals**:
   - `WithdrawnFromStrategy` events
   - `SwappedAndSent` events
   - Pending amounts accuracy

---

## Cost Estimates

### Gas Costs (Base L2)

- Deploy new implementation: ~3-4M gas
- Update factory: ~50k gas
- User vault upgrade: ~30-50k gas
- **Total per vault**: ~30-50k gas (user pays)

### Financial Cost (assuming 0.001 gwei gas price on Base)

- Deploy + update factory: ~$0.10-0.20
- Per vault upgrade: ~$0.01-0.02 (user pays)

---

## Support

For issues or questions:
1. Check deployment logs for specific errors
2. Review transaction on Basescan
3. Test on fork with `-vvvvv` for detailed traces
4. Check contract events for failure reasons

---

## References

- [Forge Scripting Guide](https://book.getfoundry.sh/tutorials/solidity-scripting)
- [UUPS Proxy Pattern](https://docs.openzeppelin.com/contracts/4.x/api/proxy#UUPSUpgradeable)
- [Two-Step Withdrawal Docs](./TWO_STEP_WITHDRAWAL.md)
- [Two-Step Withdrawal API](../../server2/docs/TWO_STEP_WITHDRAWAL_API.md)






