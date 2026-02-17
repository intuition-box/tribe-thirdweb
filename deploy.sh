#!/bin/bash
# Deploy DEXMigrationLib first, then MemeLaunchpad with library linked.
# Usage: TREASURY=0x... DEX_ROUTER=0x... ./deploy.sh
# Or: ./deploy.sh 0xTREASURY 0xDEX_ROUTER

set -e
TREASURY=${1:-$TREASURY}
ROUTER=${2:-$DEX_ROUTER}
if [ -z "$TREASURY" ] || [ -z "$ROUTER" ]; then
  echo "Usage: TREASURY=0x... DEX_ROUTER=0x... ./deploy.sh"
  echo "   Or: ./deploy.sh 0xTREASURY 0xDEX_ROUTER"
  exit 1
fi

echo "Deploying DEXMigrationLib..."
LIB=$(forge create src/DEXMigrationLib.sol:DEXMigrationLib 2>&1 | grep -oE '0x[a-fA-F0-9]{40}' | head -1)
echo "DEXMigrationLib: $LIB"

echo "Deploying MemeLaunchpad..."
forge create src/MemeLaunchpad.sol:MemeLaunchpad \
  --libraries src/DEXMigrationLib.sol:DEXMigrationLib:$LIB \
  --constructor-args $TREASURY $ROUTER
echo "Done."
