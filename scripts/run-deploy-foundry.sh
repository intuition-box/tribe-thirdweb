#!/usr/bin/env bash
# Run Foundry deploy script (script/Deploy.s.sol) with .env loaded.
# Required in .env: TREASURY, DEX_ROUTER, PRIVATE_KEY, RPC_URL

set -e
cd "$(dirname "$0")/.."

if [ -f .env ]; then
  set -a
  source <(grep -v '^#' .env | sed 's/^/export /')
  set +a
fi

for var in TREASURY DEX_ROUTER PRIVATE_KEY RPC_URL; do
  if [ -z "${!var}" ]; then
    echo "Error: $var is not set. Add it to .env or export it."
    exit 1
  fi
done

if [[ ! "$RPC_URL" =~ ^https?:// ]]; then
  RPC_URL="https://${RPC_URL}"
fi

# Clean and build with size-optimized profile
FOUNDRY_PROFILE=deploy forge clean
FOUNDRY_PROFILE=deploy forge build

echo "Deploying DEXMigrationLib and MemeLaunchpad (TREASURY=$TREASURY, DEX_ROUTER=$DEX_ROUTER)..."
FOUNDRY_PROFILE=deploy forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast
