#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# E2E Deploy & Test Script
#
# 1. Pre-flight: storage layout check
# 2. Compile with optimizer
# 3. Run existing forge e2e tests (fork tests against Base mainnet)
# 4. Optionally deploy to mainnet if --mainnet flag is passed
#
# Usage:
#   ./script/deploy-e2e.sh              # Compile + run e2e fork tests
#   ./script/deploy-e2e.sh --mainnet    # Run tests, then deploy to Base mainnet
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$CONTRACT_DIR"

MAINNET=false
if [[ "${1:-}" == "--mainnet" ]]; then
  MAINNET=true
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}✅ $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; exit 1; }
info() { echo -e "${YELLOW}→ $1${NC}"; }

echo "============================================"
echo "  AnalogVault E2E Deploy & Test"
echo "============================================"
echo ""

if [[ -z "${BASE_HTTP_RPC_URL:-}" ]]; then
  fail "BASE_HTTP_RPC_URL not set"
fi

# =============================================================================
# Step 1: Storage compatibility check
# =============================================================================
info "Running storage compatibility check..."
./script/check-storage-compat.sh || fail "Storage layout incompatible!"
echo ""

# =============================================================================
# Step 2: Compile with optimizer (for accurate code size)
# =============================================================================
info "Compiling contracts (optimizer enabled)..."
forge build --force 2>&1 | tail -3
pass "Compilation successful"
echo ""

# =============================================================================
# Step 3: Run e2e fork tests
# =============================================================================
info "Running e2e fork tests..."
echo ""

# Core tests: factory, vault creation, deposit, withdraw, upgrade auth
FOUNDRY_PROFILE=lite forge test \
  --match-contract "AnalogVaultForkTest|AnalogVaultUpgradeAuthTest|AnalogVaultWithdrawForkTest|AnalogVaultNoSwapForkTest" \
  --fork-url "$BASE_HTTP_RPC_URL" \
  -v 2>&1 | tee /tmp/e2e-results.txt | tail -20

echo ""

# Check results
PASSED=$(grep -oP '\d+ passed' /tmp/e2e-results.txt | head -1 | grep -oP '\d+')
FAILED=$(grep -oP '\d+ failed' /tmp/e2e-results.txt | head -1 | grep -oP '\d+' || echo "0")

echo "============================================"
echo "  Test Results: ${PASSED:-0} passed, ${FAILED:-0} failed"
echo "============================================"
echo ""

if [[ "${FAILED:-0}" != "0" ]]; then
  echo "Failed tests:"
  grep "FAIL" /tmp/e2e-results.txt | head -10
  echo ""
  fail "E2E tests failed — aborting deployment"
fi

pass "All e2e tests passed"
echo ""

# =============================================================================
# Step 4: Mainnet deploy (if --mainnet)
# =============================================================================
if [[ "$MAINNET" == "true" ]]; then
  if [[ -z "${DEPLOYER_PRIVATE_KEY:-}" ]]; then
    fail "DEPLOYER_PRIVATE_KEY not set for mainnet deploy"
  fi

  info "Deploying to Base mainnet..."
  echo ""

  forge script script/DeployAnalogVaultImplementation.s.sol:DeployAnalogVaultImplementation \
    --rpc-url "$BASE_HTTP_RPC_URL" \
    --broadcast \
    --slow 2>&1 | tail -20

  echo ""
  pass "Mainnet deployment complete!"
  echo ""
  echo "Next steps:"
  echo "  1. Run update-vault-factory-impl.ts on prod server to update factory"
  echo "  2. Upgrade existing vaults via upgradeToLatest()"
else
  echo "To deploy to mainnet after tests pass:"
  echo "  DEPLOYER_PRIVATE_KEY=0x... ./script/deploy-e2e.sh --mainnet"
fi
