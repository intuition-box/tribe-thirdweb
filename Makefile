-include .env
deploy:
	npx thirdweb deploy -k $(THIRD_WEB_API_KEY)
