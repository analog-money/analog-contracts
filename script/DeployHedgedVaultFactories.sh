#!/bin/bash
# Deploy AnalogHedgedUniswapVaultFactory and AvantisHedgeAdapterFactory

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Deploying Hedged Vault Factories${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check required environment variables
if [ -z "$BASE_HTTP_RPC_URL" ]; then
  echo -e "${RED}Error: BASE_HTTP_RPC_URL environment variable is required${NC}"
  exit 1
fi

# Step 1: Deploy AvantisHedgeAdapterFactory
echo -e "${YELLOW}Step 1: Deploying AvantisHedgeAdapterFactory...${NC}"
ADAPTER_FACTORY_OUTPUT=$(forge script script/DeployAvantisHedgeAdapterFactory.s.sol:DeployAvantisHedgeAdapterFactory \
  --rpc-url $BASE_HTTP_RPC_URL \
  --broadcast \
  --json 2>&1)

# Extract adapter factory address from output
ADAPTER_FACTORY_ADDRESS=$(echo "$ADAPTER_FACTORY_OUTPUT" | grep "Factory deployed at:" | sed 's/.*Factory deployed at: //' | tr -d '[:space:]')

if [ -z "$ADAPTER_FACTORY_ADDRESS" ]; then
  echo -e "${RED}Error: Failed to extract AvantisHedgeAdapterFactory address${NC}"
  echo "$ADAPTER_FACTORY_OUTPUT"
  exit 1
fi

echo -e "${GREEN}✓ AvantisHedgeAdapterFactory deployed at: $ADAPTER_FACTORY_ADDRESS${NC}"
echo ""

# Step 2: Deploy AnalogHedgedUniswapVaultFactory
echo -e "${YELLOW}Step 2: Deploying AnalogHedgedUniswapVaultFactory...${NC}"

# Use existing StrategyFactory if available, or require it as env var
STRATEGY_FACTORY_ADDRESS=${STRATEGY_FACTORY_ADDRESS:-"0xf5628a987928B642620B9eA7A1648d280F3Cd035"}
CONTROLLER_ADDRESS=${CONTROLLER_ADDRESS:-$(cast wallet address)}

echo "  Using StrategyFactory: $STRATEGY_FACTORY_ADDRESS"
echo "  Using Controller: $CONTROLLER_ADDRESS"
echo ""

VAULT_FACTORY_OUTPUT=$(HEDGE_ADAPTER_FACTORY_ADDRESS=$ADAPTER_FACTORY_ADDRESS \
  STRATEGY_FACTORY_ADDRESS=$STRATEGY_FACTORY_ADDRESS \
  CONTROLLER_ADDRESS=$CONTROLLER_ADDRESS \
  forge script script/DeployAnalogHedgedUniswapVaultFactory.s.sol:DeployAnalogHedgedUniswapVaultFactory \
  --rpc-url $BASE_HTTP_RPC_URL \
  --broadcast \
  --json 2>&1)

# Extract vault factory address from output
VAULT_FACTORY_ADDRESS=$(echo "$VAULT_FACTORY_OUTPUT" | grep "Factory Address:" | sed 's/.*Factory Address: //' | tr -d '[:space:]')
VAULT_IMPL_ADDRESS=$(echo "$VAULT_FACTORY_OUTPUT" | grep "Vault Implementation Address:" | sed 's/.*Vault Implementation Address: //' | tr -d '[:space:]')

if [ -z "$VAULT_FACTORY_ADDRESS" ]; then
  echo -e "${RED}Error: Failed to extract AnalogHedgedUniswapVaultFactory address${NC}"
  echo "$VAULT_FACTORY_OUTPUT"
  exit 1
fi

echo -e "${GREEN}✓ AnalogHedgedUniswapVaultFactory deployed at: $VAULT_FACTORY_ADDRESS${NC}"
echo -e "${GREEN}✓ Vault Implementation deployed at: $VAULT_IMPL_ADDRESS${NC}"
echo ""

# Summary
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Deployment Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Deployed Contracts:"
echo "  AvantisHedgeAdapterFactory: $ADAPTER_FACTORY_ADDRESS"
echo "  AnalogHedgedUniswapVaultFactory: $VAULT_FACTORY_ADDRESS"
echo "  Vault Implementation: $VAULT_IMPL_ADDRESS"
echo ""
echo "Next steps:"
echo "1. Update strategy config in database:"
echo "   analogHedgedUniswapVaultFactoryAddress = \"$VAULT_FACTORY_ADDRESS\""
echo "   avantisHedgeAdapterFactoryAddress = \"$ADAPTER_FACTORY_ADDRESS\""
echo ""
echo "2. Or run the database update script:"
echo "   cd apps/server2"
echo "   VAULT_FACTORY_ADDRESS=$VAULT_FACTORY_ADDRESS \\"
echo "   ADAPTER_FACTORY_ADDRESS=$ADAPTER_FACTORY_ADDRESS \\"
echo "   npx tsx scripts/update-hedged-vault-factory-addresses.ts"
echo ""

# Export addresses for subsequent scripts
export ANALOG_HEDGED_UNISWAP_VAULT_FACTORY_ADDRESS=$VAULT_FACTORY_ADDRESS
export AVANTIS_HEDGE_ADAPTER_FACTORY_ADDRESS=$ADAPTER_FACTORY_ADDRESS
export ANALOG_HEDGED_UNISWAP_VAULT_IMPL_ADDRESS=$VAULT_IMPL_ADDRESS

# Save to .env.deployed for reference
cat > .env.deployed << EOF
# Deployed on $(date)
ANALOG_HEDGED_UNISWAP_VAULT_FACTORY_ADDRESS=$VAULT_FACTORY_ADDRESS
AVANTIS_HEDGE_ADAPTER_FACTORY_ADDRESS=$ADAPTER_FACTORY_ADDRESS
ANALOG_HEDGED_UNISWAP_VAULT_IMPL_ADDRESS=$VAULT_IMPL_ADDRESS
EOF

echo -e "${GREEN}Addresses saved to .env.deployed${NC}"
