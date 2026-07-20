# Read .env into make's own variables (-include so a missing file is not an error), then export them.
-include .env
export

# UPGRADE
#
# The USDat ProxyAdmin is owned by SaturnTimelock (5-day minDelay), so the upgrade is a two-step flow:
#   1. propose-upgrade — deploy the implementation and schedule the upgrade (PROPOSER EOA only)
#   2. wait 5 days
#   3. execute-upgrade — execute the matured operation (any EOA: EXECUTOR_ROLE is open)
#
# propose-upgrade runs `forge clean` first: the OpenZeppelin validator reads out/build-info, and a stale
# build-info from a differently-scoped compile (e.g. a prior `forge test`) makes it fail with "Found
# multiple contracts with name src/USDat.sol:USDat". A clean build also ensures the deployed bytecode is
# reproducible from this commit alone — see VerifyCodeHash.
#
# --ffi is required: Upgrades.prepareUpgrade shells out to @openzeppelin/upgrades-core to validate the
# implementation before deploying it.

propose-upgrade: RPC_URL=$(MAINNET_RPC_URL)
propose-upgrade: PRIVATE_KEY=$(PROPOSER_PRIVATE_KEY)
propose-upgrade:
	forge clean
	forge script script/ProposeUSDatUpgrade.s.sol:ProposeUSDatUpgrade \
	--rpc-url $(RPC_URL) \
	--private-key $(PRIVATE_KEY) \
	--ffi --skip test --slow --non-interactive --broadcast --verify

execute-upgrade: RPC_URL=$(MAINNET_RPC_URL)
execute-upgrade:
	forge script script/ExecuteUSDatUpgrade.s.sol:ExecuteUSDatUpgrade \
	--rpc-url $(RPC_URL) \
	--private-key $(PRIVATE_KEY) \
	--skip test --slow --non-interactive --broadcast
