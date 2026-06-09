# include .env file and export its env vars
# (-include to ignore error if it does not exist)
-include .env

# UPGRADE

upgrade:
	FOUNDRY_PROFILE=production PRIVATE_KEY=$(PRIVATE_KEY) \
	forge script script/UpgradeUSDat.s.sol:UpgradeUSDat \
	--rpc-url $(RPC_URL) \
	--private-key $(PRIVATE_KEY) \
	--skip test --slow --non-interactive --broadcast --verify

upgrade-local: RPC_URL=$(LOCALHOST_RPC_URL)
upgrade-local: PRIVATE_KEY=$(PROXY_ADMIN_OWNER_PRIVATE_KEY)
upgrade-local: upgrade

upgrade-mainnet: RPC_URL=$(MAINNET_RPC_URL)
upgrade-mainnet: PRIVATE_KEY=$(PROXY_ADMIN_OWNER_PRIVATE_KEY)
upgrade-mainnet: upgrade

