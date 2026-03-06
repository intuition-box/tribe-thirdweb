-include .env

# Thirdweb CLI spawns `forge`; npx often doesn't see Foundry in PATH -> "Command 'forge' not found" gets parsed as JSON -> error.
# Use a script that puts forge's directory on PATH before running thirdweb.
deploy:
	npx thirdweb deploy -k $(THIRD_WEB_API_KEY)

# Deploy MemeLaunchpad via Foundry script (script/Deploy.s.sol); uses .env for TREASURY, DEX_ROUTER, PRIVATE_KEY, RPC_URL
deploy-foundry:
	@chmod +x scripts/run-deploy-foundry.sh 2>/dev/null || true
	./scripts/run-deploy-foundry.sh

# Run tests (MemeLaunchpad uses DEXMigrationLib via delegatecall; tests deploy lib to 0x100 and pass to constructor)
test:
	forge test
