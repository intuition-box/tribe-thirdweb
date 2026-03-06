#!/usr/bin/env bash
# Deploy MemeLaunchpad using config from .env
# Required in .env: TREASURY, DEX_ROUTER, PRIVATE_KEY, RPC_URL
# Optional: CHAIN_ID, BLOCK_EXPLORER_URL

set -e
cd "$(dirname "$0")"

# Load .env (ignore comments and export vars)
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source <(grep -v '^#' .env | sed 's/^/export /')
  set +a
fi

for var in TREASURY DEX_ROUTER PRIVATE_KEY RPC_URL; do
  if [ -z "${!var}" ]; then
    echo "Error: $var is not set. Add it to .env or export it."
    exit 1
  fi
done

# Ensure RPC_URL has a scheme
if [[ ! "$RPC_URL" =~ ^https?:// ]]; then
  RPC_URL="https://${RPC_URL}"
fi

echo "Network: RPC=$RPC_URL (CHAIN_ID=${CHAIN_ID:-not set})"
echo "Treasury: $TREASURY"
echo "DEX Router: $DEX_ROUTER"
echo "Deploying DEXMigrationLib..."
LIB_OUT=$(forge create src/DEXMigrationLib.sol:DEXMigrationLib \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" 2>&1)
LIB=$(echo "$LIB_OUT" | grep -oE 'Deployed to: 0x[a-fA-F0-9]{40}' | head -1 | awk '{print $3}')
[ -z "$LIB" ] && LIB=$(echo "$LIB_OUT" | grep -oE '0x[a-fA-F0-9]{40}' | head -1)
if [ -z "$LIB" ]; then echo "$LIB_OUT"; exit 1; fi
echo "DEXMigrationLib at: $LIB"
echo "Deploying MemeLaunchpad..."

DEPLOYED=$(forge create src/MemeLaunchpad.sol:MemeLaunchpad \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --constructor-args "$TREASURY" "$DEX_ROUTER" "$LIB" \
  2>&1)

LAUNCHPAD=$(echo "$DEPLOYED" | grep -oE 'Deployed to: 0x[a-fA-F0-9]{40}' | head -1 | awk '{print $3}')
if [ -z "$LAUNCHPAD" ]; then
  LAUNCHPAD=$(echo "$DEPLOYED" | grep -oE '0x[a-fA-F0-9]{40}' | head -1)
fi

if [ -n "$LAUNCHPAD" ]; then
  echo ""
  echo "MemeLaunchpad deployed to: $LAUNCHPAD"
  if [ -n "$BLOCK_EXPLORER_URL" ]; then
    if [[ ! "$BLOCK_EXPLORER_URL" =~ ^https?:// ]]; then
      BLOCK_EXPLORER_URL="https://${BLOCK_EXPLORER_URL}"
    fi
    echo "Explorer: ${BLOCK_EXPLORER_URL}/address/${LAUNCHPAD}"
  fi
else
  echo "$DEPLOYED"
  exit 1
fi
