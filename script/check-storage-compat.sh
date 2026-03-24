#!/usr/bin/env bash
set -euo pipefail

# Storage layout compatibility checker for AnalogVault upgrades
#
# Compares the storage layout of the current AnalogVault against a reference.
# Run BEFORE deploying a new implementation to catch incompatible changes.
#
# Usage:
#   ./script/check-storage-compat.sh                    # Compare against saved reference
#   ./script/check-storage-compat.sh --save             # Save current layout as reference
#   ./script/check-storage-compat.sh --reference FILE   # Compare against specific file

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACT_DIR="$(dirname "$SCRIPT_DIR")"
REFERENCE_FILE="$SCRIPT_DIR/.storage-reference-AnalogVault.txt"

cd "$CONTRACT_DIR"

extract_layout() {
  FOUNDRY_PROFILE=lite forge inspect src/AnalogVault.sol:AnalogVault storage-layout 2>/dev/null \
    | grep -E "^\|" \
    | grep -v "^| Name" \
    | grep -v "^\+=" \
    | sed 's/|//g; s/  */ /g; s/^ //; s/ $//' \
    | awk '{print $1, $2, $3, $4, $5}' \
    | grep -v "^$"
}

if [[ "${1:-}" == "--save" ]]; then
  echo "Saving current storage layout as reference..."
  extract_layout > "$REFERENCE_FILE"
  echo "Saved to $REFERENCE_FILE ($(wc -l < "$REFERENCE_FILE") slots)"
  exit 0
fi

if [[ "${1:-}" == "--reference" ]]; then
  REFERENCE_FILE="${2:?Usage: --reference FILE}"
fi

if [[ ! -f "$REFERENCE_FILE" ]]; then
  echo "ERROR: No reference file found at $REFERENCE_FILE"
  echo "Run with --save first to create one from the current (known-good) layout."
  exit 1
fi

echo "=== AnalogVault Storage Compatibility Check ==="
echo ""

# Extract current layout
CURRENT=$(extract_layout)
REFERENCE=$(cat "$REFERENCE_FILE")

# Compare
if diff <(echo "$REFERENCE") <(echo "$CURRENT") > /dev/null 2>&1; then
  echo "✅ Storage layout is COMPATIBLE with reference."
  echo "   All slots match. Safe to deploy as upgrade."
  exit 0
else
  echo "❌ Storage layout INCOMPATIBLE with reference!"
  echo ""
  echo "Differences (< = reference, > = current):"
  echo "---"
  diff <(echo "$REFERENCE") <(echo "$CURRENT") || true
  echo "---"
  echo ""
  echo "This implementation CANNOT be used as an upgrade for existing vaults."
  echo "Deploying this would permanently brick proxied vaults."
  exit 1
fi
