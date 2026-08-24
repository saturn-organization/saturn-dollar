# Read .env into make's own variables (-include so a missing file is not an error), then export them.
-include .env
export

# UPGRADE
#
# The USDat ProxyAdmin is owned by SaturnTimelock (5-day minDelay) and PROPOSER_ROLE is held by a Fireblocks
# MPC wallet, so deploy and propose are separate steps (the MPC wallet submits only `schedule`, and cannot
# deploy the implementation in the same broadcast):
#   1. deploy-upgrade-impl — deploy the new implementation, then hardcode the printed address into
#      UpgradeUSDatBase.NEW_IMPLEMENTATION (the propose and execute scripts rebuild the operation from it).
#      Already done for the current upgrade; NEW_IMPLEMENTATION is set. Redo only for a new implementation.
#   2. propose the upgrade against NEW_IMPLEMENTATION, either:
#        a. propose-upgrade-calldata — print the schedule() calldata to paste into the Fireblocks console, or
#        b. propose-upgrade          — broadcast schedule() through the Fireblocks JSON-RPC SDK (MPC signs).
#   3. wait 5 days
#   4. execute-upgrade — execute the matured operation.
#
# deploy-upgrade-impl runs `forge clean` first: the OpenZeppelin validator reads out/build-info, and a stale
# build-info from a differently-scoped compile (e.g. a prior `forge test`) makes it fail with "Found
# multiple contracts with name src/USDat.sol:USDat". A clean build also ensures the deployed bytecode is
# reproducible from this commit alone — see VerifyCodeHash.
#
# --ffi is required for the deploy: Upgrades.prepareUpgrade shells out to @openzeppelin/upgrades-core to
# validate the implementation before deploying it. Propose does not deploy, so it needs neither --ffi nor
# the clean build.

deploy-upgrade-impl: RPC_URL=$(MAINNET_RPC_URL)
deploy-upgrade-impl:
	forge clean
	forge script script/DeployUSDatImplementation.s.sol:DeployUSDatImplementation \
	--rpc-url $(RPC_URL) \
	--private-key $(PRIVATE_KEY) \
	--ffi --skip test --slow --non-interactive --broadcast --verify

# Dry-run only: simulates the schedule from PROPOSER_ADDRESS (no key, no broadcast) and prints the operation
# id plus the schedule() calldata for manual submission through the Fireblocks console. Schedules the
# upgrade against UpgradeUSDatBase.NEW_IMPLEMENTATION.
propose-upgrade-calldata: RPC_URL=$(MAINNET_RPC_URL)
propose-upgrade-calldata:
	forge script script/ProposeUSDatUpgrade.s.sol:ProposeUSDatUpgrade \
	--rpc-url $(RPC_URL) \
	--sender $(PROPOSER_ADDRESS) \
	--skip test --slow --non-interactive

# Broadcast schedule() through Fireblocks: the fireblocks-json-rpc SDK stands up a local JSON-RPC proxy at
# {} and forge submits the unsigned tx to it via --unlocked --sender; the Fireblocks MPC wallet signs. Needs
# FIREBLOCKS_API_KEY and FIREBLOCKS_API_PRIVATE_KEY_PATH in the environment.
propose-upgrade: RPC_URL=$(MAINNET_RPC_URL)
propose-upgrade:
	npx @fireblocks/fireblocks-json-rpc --http --rpcUrl $(RPC_URL) -- \
	forge script script/ProposeUSDatUpgrade.s.sol:ProposeUSDatUpgrade \
	--rpc-url {} \
	--sender $(PROPOSER_ADDRESS) --unlocked \
	--skip test --slow --non-interactive --broadcast \
	--rpc-timeout 1800 --timeout 600

execute-upgrade: RPC_URL=$(MAINNET_RPC_URL)
execute-upgrade:
	forge script script/ExecuteUSDatUpgrade.s.sol:ExecuteUSDatUpgrade \
	--rpc-url $(RPC_URL) \
	--private-key $(PRIVATE_KEY) \
	--skip test --slow --non-interactive --broadcast
