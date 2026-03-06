#!/usr/bin/env bash
set -e
# Thirdweb CLI spawns `forge`; if PATH doesn't include Foundry you get "Command 'forge' not found" parsed as JSON -> error.
FORGE_PATH=$(command -v forge 2>/dev/null) || true
if [ -z "$FORGE_PATH" ]; then
  echo "Error: forge not found. Install Foundry: curl -L https://foundry.paradigm.xyz | bash && foundryup"
  exit 1
fi
FOUNDRY_BIN=$(dirname "$FORGE_PATH")
export PATH="$FOUNDRY_BIN:$PATH"
cd "$(dirname "$0")/.."
forge build
# Run thirdweb with PATH set in the same env so its forge subprocess sees it (required on some systems).
env PATH="$FOUNDRY_BIN:$PATH" npx thirdweb deploy -k "$THIRD_WEB_API_KEY" "$@"
