# Timelock-Routed USDat Upgrade Scripts

**Date:** 2026-07-16
**Status:** Implemented — see "Implementation notes" at the end for deviations found while building it.
**Scope:** Restructure the upgrade flow from the dead "broadcast `Upgrades.upgradeProxy` as the ProxyAdmin-owner EOA" model to the real timelock-routed path: propose (deploy impl + schedule) -> wait 5 days -> execute.

---

## Context

The ProxyAdmin for the USDat proxy (`0x23238f20...`) was transferred from the EOA `0x6101...6820` to SaturnTimelock (`0xfD57...8A67`, an OZ TimelockController with a 5-day / 432,000s minDelay) at block 25,284,032. The EOA `0x6101...6820` holds PROPOSER and CANCELLER roles; EXECUTOR is granted to `address(0)`, meaning anyone can execute a matured operation.

The current `UpgradeUSDat.s.sol` broadcasts `Upgrades.upgradeProxy` as the owner EOA. This reverts on mainnet because `ProxyAdmin.upgradeAndCall` is `onlyOwner` and the owner is now the timelock. The fork test passes only because it forks at block 25,280,870 (before the ownership transfer).

The real flow requires:

1. Deploy the new USDat implementation (permissionless, any EOA).
2. Schedule `ProxyAdmin.upgradeAndCall(proxy, impl, migrate(M_TOKEN))` via `timelock.schedule(...)` as the PROPOSER EOA.
3. Wait out the 5-day delay, then anyone calls `timelock.execute(...)`.

`migrate()` already calls `stopEarning()` and mints any surplus (M yield accrued during the delay) to the yield recipient, so the pre-call to `claimYield()` is dropped entirely.

---

## File changes

### 1. Rewrite `script/UpgradeUSDatBase.sol`

Keep the address constants (`USDAT_PROXY`, `M_TOKEN`, `PYUSDX`, `PYUSDX_SWAP_FACILITY`) and the `IJMIExtensionLegacy` interface (still needed by the fork test for pre-upgrade state checks).

Add constant:
```solidity
address constant TIMELOCK = 0xfD57...8A67; // SaturnTimelock (full address)
```

Replace `_upgradeAndMigrate()` with two helpers:
```solidity
/// @dev Deploy the new implementation (permissionless, any EOA).
function _deployImplementation() internal returns (address impl) {
    Options memory opts;
    opts.constructorData = abi.encode(PYUSDX, PYUSDX_SWAP_FACILITY);
    opts.unsafeSkipStorageCheck = true;
    opts.unsafeAllow = "missing-initializer";
    impl = Upgrades.prepareUpgrade("USDat.sol", opts);
}

/// @dev Build the single upgradeAndCall calldata: ProxyAdmin.upgradeAndCall(proxy, impl, migrate(M_TOKEN))
function _buildUpgradeAndCallData(address impl)
    internal
    view
    returns (address proxyAdmin, bytes memory payload)
{
    proxyAdmin = Upgrades.getAdminAddress(USDAT_PROXY);
    payload = abi.encodeCall(IProxyAdmin.upgradeAndCall,
        (USDAT_PROXY, impl, abi.encodeCall(USDat.migrate, (M_TOKEN))));
}
```

**Drop the `claimYield()` pre-call entirely.** `migrate()` already calls `stopEarning()` and mints any surplus to the yield recipient. Yield accrues during the 5-day timelock delay and is absorbed by the surplus logic.

New imports:
```solidity
import {IProxyAdmin} from "openzeppelin-foundry-upgrades/internal/interfaces/IProxyAdmin.sol";
import {TimelockController} from "openzeppelin-contracts/contracts/governance/TimelockController.sol";
```

Note the `IProxyAdmin` path has **no `src/` segment**: `forge remappings` maps `openzeppelin-foundry-upgrades/` to `.../openzeppelin-foundry-upgrades/src/` already, so including `src/` would resolve to `src/src/...` and fail to compile. Both paths are resolvable via existing remappings. **No `TimelockBatchBase`** - we use `schedule` / `execute` directly since there is exactly one operation.

`prepareUpgrade` works without a reference contract here: with `unsafeSkipStorageCheck = true` the validate command drops `--requireReference` (verified in `Core.buildValidateCommand`). This matters because the old flow relied on `upgradeProxy` inferring the reference from the live proxy.

### 2. New `script/ProposeUSDatUpgrade.s.sol` (merged deploy + schedule)

Deploys the implementation AND schedules the timelock operation in a single `forge script` run, signed by the proposer EOA (via `--private-key`; no env-var key derivation - one source of truth). Uses `TimelockController.schedule` (single op, not batch):
```solidity
contract ProposeUSDatUpgrade is Script, UpgradeUSDatBase {
    function run() public {
        TimelockController timelock = TimelockController(payable(TIMELOCK));

        // Sanity: the broadcast sender must hold PROPOSER_ROLE and the delay must be as expected.
        (, address sender,) = vm.readCallers();
        require(timelock.hasRole(timelock.PROPOSER_ROLE(), sender), "sender lacks PROPOSER_ROLE");
        uint256 delay = timelock.getMinDelay();
        require(delay == 5 days, "unexpected minDelay");

        // Step 1: Deploy the new implementation (permissionless)
        vm.startBroadcast();
        address impl = _deployImplementation();
        vm.stopBroadcast();

        console.log("New Implementation:", impl);

        // Step 2: Build the upgradeAndCall calldata
        (address proxyAdmin, bytes memory payload) = _buildUpgradeAndCallData(impl);

        // Step 3: Dry-run the exact payload as the timelock in simulation state (never broadcast).
        //         Proves the scheduled bytes execute against current mainnet state; only mutates
        //         throwaway simulation state, and `schedule` itself doesn't read proxy state.
        vm.prank(TIMELOCK);
        (bool ok,) = proxyAdmin.call(payload);
        require(ok, "upgradeAndCall payload would revert");

        // Step 4: Schedule via the timelock (single schedule, not batch)
        vm.startBroadcast();
        timelock.schedule(proxyAdmin, 0, payload, bytes32(0), bytes32(0), delay);
        vm.stopBroadcast();

        console.log("Timelock operation id:");
        console.logBytes32(timelock.hashOperation(proxyAdmin, 0, payload, bytes32(0), bytes32(0)));
        console.log("Scheduled. Execute after %s seconds.", delay);
        console.log("Pass NEW_IMPLEMENTATION=%s to the execute script.", impl);
    }
}
```

Run with `--broadcast --verify` so the implementation is deployed, verified, and the schedule tx broadcast in one go.

**Why the explicit dry-run (Step 3):** simulating the `schedule` tx does NOT transitively execute the `upgradeAndCall` it encodes - the payload is inert calldata stored in the timelock until `execute` five days later. A broken payload discovered at execute time costs the full delay (cancel via CANCELLER, re-propose, wait another 5 days). The `vm.prank(TIMELOCK)` call runs the exact scheduled bytes during forge's simulation phase at zero cost. The fork test is the primary safety net; this is belt-and-braces at propose time against live state.

**Operation id logging:** `hashOperation(...)` is what you track on-chain (`getTimestamp`, `isOperationReady`) and what the CANCELLER needs to abort.

### 3. New `script/ExecuteUSDatUpgrade.s.sol`

Takes `NEW_IMPLEMENTATION` as env var. Rebuilds the same calldata and broadcasts `timelock.execute`:
```solidity
contract ExecuteUSDatUpgrade is Script, UpgradeUSDatBase {
    function run() public {
        address impl = vm.envAddress("NEW_IMPLEMENTATION");

        (address proxyAdmin, bytes memory payload) = _buildUpgradeAndCallData(impl);

        TimelockController timelock = TimelockController(payable(TIMELOCK));
        bytes32 id = timelock.hashOperation(proxyAdmin, 0, payload, bytes32(0), bytes32(0));
        require(timelock.isOperationReady(id), "operation not ready (wrong impl, not scheduled, or delay not elapsed)");

        vm.startBroadcast();
        timelock.execute(proxyAdmin, 0, payload, bytes32(0), bytes32(0));
        vm.stopBroadcast();
    }
}
```

A wrong `NEW_IMPLEMENTATION` is self-protecting either way - the rebuilt payload hashes to an unknown operation id and the timelock reverts - but the `isOperationReady` pre-check turns that into a readable error before any gas is spent.

### 4. Delete `script/UpgradeUSDat.s.sol`

The broadcast-as-owner path is dead on mainnet (ProxyAdmin is owned by the timelock). `VerifyCodeHash.s.sol` stays - it only uses the constants from the base.

### 5. Rewrite `test/UpgradeUSDatFork.t.sol`

Fork at block **25,284,032** (post ownership-transfer to the timelock). Model the real multi-step flow:
```
setUp:
  fork(MAINNET_RPC_URL, 25_284_032)

helper _doTimelockUpgrade(address impl):
  // build upgradeAndCall calldata via _buildUpgradeAndCallData
  // schedule as PROPOSER (vm.prank)
  timelock.schedule(proxyAdmin, 0, payload, 0, 0, delay)
  // warp past delay
  vm.warp(block.timestamp + 5 days + 1)
  // execute as anyone (vm.prank(alice))
  timelock.execute(proxyAdmin, 0, payload, 0, 0)

test_upgradeAndMigrate_timelock:
  // snapshot pre-upgrade state (balances, totalSupply, totalAssets - NOT yield, see below)
  // _doTimelockUpgrade(impl)
  // assert all post-migration state (checks adapted from current test_upgradeAndMigrate)

test_migrate_absorbsYieldAccruedDuringTimelockDelay:
  // schedule as PROPOSER
  // vm.warp(5 days) - yield accrues during the delay
  // snapshot yield() AFTER the warp, immediately before execute
  // execute
  // assert surplus was minted to yieldRecipient, M registered correctly
  // (replaces test_migrate_absorbsYieldAccruedAfterClaim - the real-world hazard)
```

**Yield-snapshot timing trap:** the current `test_upgradeAndMigrate` snapshots `pendingYield = legacyProxy.yield()` before the upgrade and asserts `totalSupply == totalSupplyBefore + pendingYield`. In the timelock flow, `_doTimelockUpgrade` warps 5 days between schedule and execute, so yield keeps accruing *after* any pre-schedule snapshot - copying the assertions naively will fail. Either snapshot `yield()` after the warp (split the helper, or have it return the pre-execute yield), or assert with inequalities (`totalSupply >= totalSupplyBefore + preScheduleYield`) in `test_upgradeAndMigrate_timelock` and leave the exact surplus accounting to `test_migrate_absorbsYieldAccruedDuringTimelockDelay`.

**Re-pin state constants to the new fork block.** `test_preUpgrade_state` hard-codes `totalSupply == 122_337_733_118939` and USDC balance `100_000001`, and `test_upgrade_preservesHolderBalances` hard-codes the Pendle holder balance `58_745_630_170210` - all pinned to block 25,280,870. At 25,284,032 at least totalSupply/yield differ. Re-read the values at the new block and update the constants.

**Rename `PROXY_ADMIN_OWNER` to `PROPOSER`.** The constant `0x6101...6820` is no longer the ProxyAdmin owner (the timelock is); it is the address the new tests prank as PROPOSER when scheduling. It still holds `DEFAULT_ADMIN_ROLE` on the token, so `test_upgrade_preservesRoles` keeps asserting against it under the new name.

- **Drop** `test_upgradeAndMigrate` (EOA-owner path) and `_upgradeAndMigrateAsOwner`.
- **Keep** `test_preUpgrade_state`, `test_upgrade_preservesHolderBalances`, `test_upgrade_preservesRoles` (adapted to call `_doTimelockUpgrade` instead, with constants re-pinned as above).

### 6. Update `Makefile`

Keep the old target's `--skip test --slow --non-interactive` flags: `--skip test` in particular means a fork-test compile issue can never block a mainnet operation.
```makefile
propose-upgrade: RPC_URL=$(MAINNET_RPC_URL)
propose-upgrade: PRIVATE_KEY=$(PROPOSER_PRIVATE_KEY)
propose-upgrade:
	forge script script/ProposeUSDatUpgrade.s.sol:ProposeUSDatUpgrade \
	  --rpc-url $(RPC_URL) --private-key $(PRIVATE_KEY) \
	  --skip test --slow --non-interactive --broadcast --verify

execute-upgrade: RPC_URL=$(MAINNET_RPC_URL)
execute-upgrade:
	forge script script/ExecuteUSDatUpgrade.s.sol:ExecuteUSDatUpgrade \
	  --rpc-url $(RPC_URL) --private-key $(PRIVATE_KEY) \
	  --skip test --slow --non-interactive --broadcast
```

### 7. Update `.env.example`
```
LOCALHOST_RPC_URL=http://127.0.0.1:8545
MAINNET_RPC_URL=
ETHERSCAN_API_KEY=
MAINNET_VERIFIER_URL="https://api.etherscan.io/v2/api?chainid=1"

# Timelock proposer EOA (0x6101...6820) - passed as --private-key by propose-upgrade (deploy + schedule)
PROPOSER_PRIVATE_KEY=

# Any EOA - used for execute-upgrade (open executor)
PRIVATE_KEY=

# New implementation address (printed by propose-upgrade, needed for execute-upgrade)
NEW_IMPLEMENTATION=
```

---

## Key design notes

- **`schedule` / `execute`, not `scheduleBatch` / `executeBatch`.** There is exactly one operation; no need for `TimelockBatchBase`, array storage, or batch encoding. Simpler and more readable.
- **Simulating `schedule` does NOT simulate the payload.** The `upgradeAndCall` bytes are inert calldata inside the timelock until `execute` five days later, so forge's pre-broadcast simulation of the propose script only proves `schedule` succeeds. Coverage of the payload itself comes from two places: the fork test (primary - runs the full schedule/warp/execute flow), and the propose script's explicit `vm.prank(TIMELOCK)` dry-run of the exact payload bytes against live state during simulation (belt-and-braces).
- **No `claimYield` in any step.** `migrate()` already calls `stopEarning()` and mints surplus. The 5-day delay means yield accrues between schedule and execute; the surplus-absorbing logic in `migrate` handles this.
- **No Safe library dependency.** The proposer EOA broadcasts `schedule` directly.
- **One source of truth for keys.** Scripts use bare `vm.startBroadcast()`; the sender comes exclusively from `--private-key` set by the Makefile. No `vm.envUint(...PRIVATE_KEY)` derivation in script code.
- **`IProxyAdmin`** imported from `openzeppelin-foundry-upgrades/internal/interfaces/IProxyAdmin.sol` (no `src/` - the remapping already points at `src/`).
- **`TimelockController`** imported from `openzeppelin-contracts/contracts/governance/TimelockController.sol` (already remapped).
- **`prepareUpgrade` needs no reference contract** when `unsafeSkipStorageCheck = true` - the validate command omits `--requireReference`.

## Pre-implementation verification (on-chain)

The design rests on three on-chain claims - verify each against mainnet when filling in the `TIMELOCK` constant:

1. The full SaturnTimelock address (`0xfD57...8A67`) is the current owner of the USDat ProxyAdmin.
2. `EXECUTOR_ROLE` is granted to `address(0)` (open executor - anyone can execute; this is what lets `execute-upgrade` use any EOA).
3. `getMinDelay() == 432_000` (5 days), and the proposer EOA `0x6101...6820` holds `PROPOSER_ROLE` (and `CANCELLER_ROLE`, needed to abort a bad operation).

**All three verified.** `TIMELOCK = 0xfD5782E3BFF366601da3973aE30C583dE4F08A67`, ProxyAdmin = `0xcf1072DA5f0D127AEf99136489BAd08bFa3D1A7D`. The handover is exactly at block 25,284,032 (the EOA owns the ProxyAdmin at 25,284,031, the timelock owns it at 25,284,032), which confirms the fork block choice.

---

## Implementation notes

What the plan got wrong or left out, discovered while building it. All corrections are in the committed code.

### The proposer EOA no longer holds the token's `DEFAULT_ADMIN_ROLE`

The plan asserted the EOA "still holds `DEFAULT_ADMIN_ROLE` on the token, so `test_upgrade_preservesRoles` keeps asserting against it under the new name." **False at the fork block.** The same governance handover that moved the ProxyAdmin also moved the token's `DEFAULT_ADMIN_ROLE` from the EOA to the timelock. Verified on-chain at 25,284,032:

| Role | Holder |
|---|---|
| `DEFAULT_ADMIN_ROLE` | TIMELOCK (EOA: false) |
| all other roles | unchanged (ROLE_MANAGER / YIELD_RECIPIENT_MANAGER / ASSET_CAP_MANAGER) |

`test_upgrade_preservesRoles` now asserts the timelock holds it and the proposer does not.

### `vm.prank` is consumed by view calls in argument position

`timelock.schedule(..., timelock.getMinDelay())` silently broke: the `getMinDelay()` staticcall is evaluated first and eats the prank, so `schedule` ran as the test contract and reverted with `AccessControlUnauthorizedAccount`. The delay must be read into a local before the prank.

### The Makefile as planned would fail at propose time

Three separate gaps, all fixed and verified:

1. **`--ffi` is required.** `Upgrades.prepareUpgrade` shells out to `@openzeppelin/upgrades-core` to validate. Neither `foundry.toml` nor the planned Makefile enabled FFI, so `propose-upgrade` died with "FFI is disabled". (`execute-upgrade` does not need it — it never calls `prepareUpgrade`.)
2. **`forge clean` is required before propose.** The OZ validator reads `out/build-info`; a build-info left by a differently-scoped compile (`forge test`, or a prior `--skip test` run) makes it fail with *"Found multiple contracts with name src/USDat.sol:USDat"*. This also makes the deployed bytecode reproducible from the commit alone, which is what `VerifyCodeHash` depends on.
3. **`export` is required.** `-include .env` defines the vars in make but does **not** put them in the recipe's environment, so `vm.envAddress("NEW_IMPLEMENTATION")` and `--verify`'s `ETHERSCAN_API_KEY` would both have seen nothing. A bare `export` directive fixes it. (The old Makefile only worked around this for `PRIVATE_KEY`.)

### Verification performed

- All 60 tests pass (`forge test --ffi`, 5 fork tests + 55 unit), `forge fmt --check` clean.
- `ProposeUSDatUpgrade` simulated end-to-end against live mainnet as the real proposer: role check, delay check, deploy, payload dry-run, and `schedule` all succeed. The dry-run records **exactly 2 transactions** (CREATE + `schedule`) — the `vm.prank(TIMELOCK)` payload check is correctly *not* broadcast.
- `ExecuteUSDatUpgrade` rebuilds operation id `0x356fe3de…`, byte-identical to the one `ProposeUSDatUpgrade` printed. This is the cross-script invariant that matters, and it holds.
- The `isOperationReady` guard trips with its readable message against mainnet (nothing scheduled there).

### Known, pre-existing, out of scope

The fork test needs `MAINNET_RPC_URL` and `--ffi`; CI runs plain `forge test -vvv` with neither, so `UpgradeUSDatFork.t.sol` cannot pass in CI. This predates these changes (the old fork test had identical requirements) and was left alone.
