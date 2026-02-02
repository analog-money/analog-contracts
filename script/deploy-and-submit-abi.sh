#!/bin/bash
# Deploy AnalogVault implementation and submit ABI to Basescan
#
# Usage:
#   ./script/deploy-and-submit-abi.sh
#
# Required environment variables:
#   - DEPLOYER_PRIVATE_KEY: Private key for deployment
#   - BASESCAN_API_KEY: Basescan API key for ABI submission
#   - FACTORY_ADDRESS: (optional) Factory address to update
#
# Example:
#   DEPLOYER_PRIVATE_KEY=0x... \
#   BASESCAN_API_KEY=your_key \
#   FACTORY_ADDRESS=0x... \
#   ./script/deploy-and-submit-abi.sh

set -e

echo "========================================"
echo "Deploy and Submit ABI Script"
echo "========================================"
echo ""

# Check required environment variables
if [ -z "$DEPLOYER_PRIVATE_KEY" ]; then
  echo "❌ Error: DEPLOYER_PRIVATE_KEY is required"
  exit 1
fi

# Support both ETHERSCAN_API_KEY and BASESCAN_API_KEY
if [ -z "$ETHERSCAN_API_KEY" ] && [ -z "$BASESCAN_API_KEY" ]; then
  echo "❌ Error: ETHERSCAN_API_KEY is required"
  echo "   Set it in .env file or as environment variable"
  echo "   Get your API key from: https://basescan.org/myapikey"
  exit 1
fi

# Set defaults
RPC_URL="${BASE_HTTP_RPC_URL:-https://mainnet.base.org}"
FACTORY_ADDRESS="${FACTORY_ADDRESS:-}"

echo "Configuration:"
echo "  RPC URL: $RPC_URL"
echo "  Factory Address: ${FACTORY_ADDRESS:-not set}"
echo ""

# Step 1: Deploy
echo "Step 1: Deploying AnalogVault implementation..."
echo ""

if [ -n "$FACTORY_ADDRESS" ]; then
  DEPLOY_OUTPUT=$(DEPLOYER_PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY" \
    FACTORY_ADDRESS="$FACTORY_ADDRESS" \
    forge script script/DeployAnalogVaultImplementation.s.sol:DeployAnalogVaultImplementation \
    --rpc-url "$RPC_URL" \
    --broadcast \
    --verify 2>&1)
else
  DEPLOY_OUTPUT=$(DEPLOYER_PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY" \
    forge script script/DeployAnalogVaultImplementation.s.sol:DeployAnalogVaultImplementation \
    --rpc-url "$RPC_URL" \
    --broadcast \
    --verify 2>&1)
fi

# Extract contract address from deployment output
CONTRACT_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep -oP 'New Implementation deployed at: \K0x[a-fA-F0-9]{40}' || \
                   echo "$DEPLOY_OUTPUT" | grep -oP 'New AnalogVault Implementation: \K0x[a-fA-F0-9]{40}' || \
                   echo "")

if [ -z "$CONTRACT_ADDRESS" ]; then
  echo "❌ Error: Could not extract contract address from deployment output"
  echo "Deployment output:"
  echo "$DEPLOY_OUTPUT"
  exit 1
fi

echo "✅ Deployment complete!"
echo "   Contract address: $CONTRACT_ADDRESS"
echo ""

# Step 2: Submit ABI
echo "Step 2: Submitting ABI to Basescan..."
echo ""

# Use ETHERSCAN_API_KEY if available, otherwise fall back to BASESCAN_API_KEY
API_KEY="${ETHERSCAN_API_KEY:-${BASESCAN_API_KEY}}"
ETHERSCAN_API_KEY="$API_KEY" \
  CONTRACT_NAME="AnalogVault" \
  CONTRACT_ADDRESS="$CONTRACT_ADDRESS" \
  npx tsx script/submit-abi-to-basescan.ts

echo ""
echo "========================================"
echo "All done!"
echo "========================================"
echo "Contract: $CONTRACT_ADDRESS"
echo "View on Basescan: https://basescan.org/address/$CONTRACT_ADDRESS#code"
echo ""

