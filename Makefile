-include .env

# Thirdweb CLI runs `forge` in a subprocess; npx can inherit a minimal PATH where forge isn't found, causing "Command 'f'... is not valid JSON".
# Prepend the directory containing forge to PATH so the deploy step sees it.
deploy:
	@command -v forge >/dev/null 2>&1 || { echo "Error: forge not found. Install Foundry: curl -L https://foundry.paradigm.xyz | bash && foundryup"; exit 1; }
	forge build
	PATH="$$(dirname $$(command -v forge)):$$PATH" npx thirdweb deploy -k $(THIRD_WEB_API_KEY)
