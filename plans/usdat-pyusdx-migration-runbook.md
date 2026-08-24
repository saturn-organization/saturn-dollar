# USDat → PYUSDX Migration Runbook

**Last updated:** 2026-08-20

**Status:** The implementation deployment and timelocked proxy upgrade are recorded as successfully executed on mainnet. The M → PYUSDX reserve wind-down and final M-cap operation remain state-dependent operational steps.

**Scope:** The implemented upgrade, migration accounting, optional `replaceAsset` restriction, ongoing M-yield handling, and final removal of M as an allowed asset.

## 1. Source of truth

This runbook follows the checked-in implementation and scripts:

- `src/USDat.sol`
- `script/PYUSDx_Deployment_Scripts/UpgradeUSDatBase.sol`
- `script/PYUSDx_Deployment_Scripts/DeployUSDatImplementation.s.sol`
- `script/PYUSDx_Deployment_Scripts/ProposeUSDatUpgrade.s.sol`
- `script/PYUSDx_Deployment_Scripts/ExecuteUSDatUpgrade.s.sol`
- `script/PYUSDx_Deployment_Scripts/ProposeReplaceAssetWhitelist.s.sol`
- `script/PYUSDx_Deployment_Scripts/ExecuteReplaceAssetWhitelist.s.sol`
- `script/PYUSDx_Cleanup_Scripts/ProposeZeroMAssetCap.s.sol`
- `script/PYUSDx_Cleanup_Scripts/ExecuteZeroMAssetCap.s.sol`
- `test/UpgradeUSDatFork.t.sol`

If this document conflicts with those files, the code is authoritative and the runbook must be updated before the next operation.

## 2. Current design

USDat uses an existing `TransparentUpgradeableProxy` at `0x23238f20b894f29041f48D88eE91131C395Aaa71`. The proxy previously ran an M-backed `JMIExtension` implementation. The current implementation inherits PYUSDX `MultiMint` and `ForcedTransferable`.

This is an upgrade-only implementation:

- it has no production `initialize` function;
- its constructor pins PYUSDX and the PYUSDX SwapFacility as immutables;
- it exposes `migrate()` as a one-shot `reinitializer(2)`; and
- `migrate()` is called atomically as the data passed to `ProxyAdmin.upgradeAndCall`.

The implementation overrides the `MultiMint` and `YieldToOne` storage accessors so they continue using the legacy JMIExtension and MYieldToOne ERC-7201 storage slots. Existing balances, roles, yield-recipient state, alt-asset state, and total-asset accounting therefore remain in the proxy.

### Important behavior changes

| Concern | Legacy JMIExtension | Current USDat/MultiMint implementation |
|---|---|---|
| Primary backing | M | PYUSDX |
| Legacy M reserve | Primary backing | Registered as a replaceable 6-decimal alternative asset |
| M earning | Enabled | Deliberately remains enabled during the reserve wind-down |
| M yield | `claimYield()` | Permissionless `claimMYield()` |
| PYUSDX yield | Not applicable | Inherited permissioned `claimYield()` |
| Unwrap output | M | PYUSDX |
| Upgrade entry point | `initialize` on the original deployment | One-shot `migrate()` |
| Version pinning | Beacon-oriented behavior | Disabled; `pinVersion` and `unpinVersion` revert |
| Compliance whitelist | Existing USDat behavior | Preserved for wrap and unwrap; separate whitelist controls `replaceAsset` callers |

There is no pre-upgrade `claimYield()` call in the current upgrade scripts. Yield can accrue during the 5-day timelock delay, and `migrate()` absorbs that surplus at execution time.

## 3. Mainnet constants

| Item | Address |
|---|---|
| USDat proxy | `0x23238f20b894f29041f48D88eE91131C395Aaa71` |
| Current implementation | `0x496a4A33b6181F4536203488d9a05AC1429E702c` |
| ProxyAdmin | `0xcf1072DA5f0D127AEf99136489BAd08bFa3D1A7D` |
| Upgrade timelock | `0xfD5782E3BFF366601da3973aE30C583dE4F08A67` |
| Asset-cap timelock | `0x7D343D17896D2cd87A49b4fB8872298A883f78f7` |
| M token | `0x866A2BF4E572CbcF37D5071A7a58503Bfb36be1b` |
| PYUSDX | `0xeBDB0942cE16386Ab90718C7BD10C91CDb66b14d` |
| PYUSDX SwapFacility | `0x0bC305e7e13113cAEd3f5486849e9518a1cC4173` |
| M0 solver | `0x81D22b74FFC5aFa7F5d70404390233a8C45F3b92` |

Both timelocks have a 5-day minimum delay and open execution through `EXECUTOR_ROLE` granted to `address(0)`.

- Upgrade proposer/canceller: `0x610182581C93687Ca03F4a8E7f124f8cEC616820`
- Asset-cap proposer/canceller: `0xA18f34a03788CfC566Ce5CCB21b2715f072dA3Ad`

The script constants use `bytes32(0)` for both the operation predecessor and salt. Proposal and execution must rebuild identical target, value, calldata, predecessor, and salt values.

## 4. Prerequisites

Before proposing a future migration or repeating the process on another deployment:

1. Confirm every address in `UpgradeUSDatBase` against the target chain.
2. Confirm the ProxyAdmin is owned by the configured upgrade timelock.
3. Confirm the proposer and canceller roles on both timelocks.
4. Confirm `EXECUTOR_ROLE` is open if permissionless execution is expected.
5. Confirm USDat is configured as a PYUSDX earner if PYUSDX yield is required.
6. Confirm USDat is approved by the PYUSDX extension registry before enabling user SwapFacility operations.
7. Run the full fork suite against the intended pre-execution block.

PYUSDX earner configuration and extension-registry approval are external operations; this repository does not currently provide scripts for them.

## 5. Implemented upgrade sequence

### Step 1 — Deploy the implementation

`DeployUSDatImplementation` calls `UpgradeUSDatBase._deployImplementation()`.

The deployment:

- uses constructor arguments `(PYUSDX, PYUSDX_SWAP_FACILITY)`;
- runs OpenZeppelin upgrade validation through `Upgrades.prepareUpgrade`;
- explicitly skips automatic storage-layout comparison because the implementation uses legacy storage-slot adapters; and
- allows the missing initializer because production migration uses `migrate()` on an already-initialized proxy.

Command:

```bash
make deploy-upgrade-impl
```

After deployment, hardcode the resulting address as `UpgradeUSDatBase.NEW_IMPLEMENTATION`. The current value is `0x496a4A33b6181F4536203488d9a05AC1429E702c`, deployed at mainnet block `25,741,375` from commit `30df5c2`.

Do not redeploy for the already-recorded migration. This step applies to future implementations.

### Step 2 — Build and propose the upgrade

`ProposeUSDatUpgrade` builds this operation:

```text
SaturnTimelock.execute(
  ProxyAdmin,
  0,
  ProxyAdmin.upgradeAndCall(USDat proxy, NEW_IMPLEMENTATION, USDat.migrate()),
  bytes32(0),
  bytes32(0)
)
```

Before scheduling, the script impersonates the timelock in simulation and calls the exact ProxyAdmin payload. This catches an invalid upgrade or migration payload before starting the 5-day delay. The simulation does not broadcast the upgrade.

The schedule can be prepared for manual Fireblocks submission:

```bash
make propose-upgrade-calldata
```

Or submitted through the Fireblocks JSON-RPC bridge:

```bash
make propose-upgrade
```

Record the implementation, operation ID, transaction hash, proposal block, and earliest execution timestamp. The tracked mainnet proposal used transaction `0xee15b16cff07b7d34ae52e344f57ea6036efaba5888bbbf1e1c2b58c13ea64ee`.

### Step 3 — Wait for the timelock

Wait at least `timelock.getMinDelay()` from the mined schedule transaction. For the configured timelock this is 432,000 seconds, or 5 days.

State can change during this period. In particular, M remains earning. The migration intentionally reads reserves at execution time rather than relying on a proposal-time snapshot.

### Step 4 — Execute the upgrade and migration

`ExecuteUSDatUpgrade` rebuilds the same operation and requires `timelock.isOperationReady(id)` before broadcasting.

```bash
make execute-upgrade
```

Execution is permissionless because the timelock's `EXECUTOR_ROLE` is open. The executing EOA only needs gas; it does not need a USDat role.

The implementation change and `migrate()` call are atomic inside `ProxyAdmin.upgradeAndCall`. There is no interval in which the new implementation is active but unmigrated.

The tracked mainnet execution succeeded in transaction `0x489450d4a23d076918ce70adbc4c5693b6634728269ba5991f355447c699b51f` at block `25,789,911`.

## 6. What `migrate()` does

At execution time:

```text
mBalance = M.balanceOf(USDat)
backing  = totalSupply() - totalAssets()
```

If `mBalance < backing`, migration reverts with `MReservesMismatch(mBalance, backing)`.

Otherwise:

1. `surplus = mBalance - backing`.
2. If the surplus is nonzero, emit `YieldClaimed(surplus)` and mint that amount of USDat to `yieldRecipient()`.
3. Register M in `MultiMint` storage with:
   - `cap = mBalance`
   - `balance = mBalance`
   - `decimals = 6`
4. Increase `totalAssets` by `mBalance`.
5. Emit `AssetCapSet(M_TOKEN, mBalance)`.

`migrate()` does not call `stopEarning()`. M remains earning across and after the upgrade.

Because `cap == balance` immediately after migration, new M wraps are initially blocked. PYUSDX unwrap capacity is initially limited by the PYUSDX actually held by USDat and grows as M is replaced.

## 7. Optional replaceAsset caller restriction

`replaceAsset` has a separate caller whitelist from USDat's compliance whitelist. The implemented scripts restrict it to the configured M0 solver.

The asset-cap timelock is independent of the upgrade timelock, so the whitelist operation can be scheduled in parallel with the upgrade:

1. Run `ProposeReplaceAssetWhitelist` as the asset-cap timelock proposer.
2. Wait for its 5-day delay in parallel with the upgrade delay.
3. Execute the USDat upgrade first so the `setReplaceAssetWhitelistCaller` selector exists on the proxy.
4. Run `ExecuteReplaceAssetWhitelist` after both operations are ready.

Before the whitelist operation executes, an empty `replaceAsset` whitelist means the operation is permissionless. After execution, the current configuration permits only `0x81D22b74FFC5aFa7F5d70404390233a8C45F3b92`.

The mainnet-fork suite verifies that this parallel scheduling order works.

## 8. Ongoing M yield

M yield accrues outside `MultiMint`'s tracked asset balance. Anyone may call `claimMYield()` while M remains an allowed asset.

The function:

1. Requires `isAllowedAsset(M_TOKEN)`.
2. Requires the configured yield recipient not to be frozen.
3. Calculates `surplus = M.balanceOf(USDat) - assetBalanceOf(M)`, floored at zero.
4. Adds the surplus to M's tracked balance and `totalAssets`.
5. Mints the same amount of USDat to `yieldRecipient()`.

The caller cannot redirect the mint. A zero-surplus call returns zero without changing state.

Operationally, call `claimMYield()` regularly while the M reserve is being drained so accrued M becomes tracked backing and can also be replaced with PYUSDX.

## 9. M → PYUSDX reserve wind-down

Use the PYUSDX SwapFacility `replaceAsset` path to deposit PYUSDX and receive tracked M 1:1. Each replacement:

- decreases `assetBalanceOf(M)` and `totalAssets`;
- transfers M out of USDat; and
- increases the proxy's PYUSDX backing.

Continue until `assetBalanceOf(M) == 0`.

### Cap behavior during the drain

Migration sets `assetCap(M) == assetBalanceOf(M)`. `replaceAsset` decreases the balance without decreasing the cap, which opens M wrap headroom. The compliance whitelist limits who can wrap, but operators must account for this behavior during the wind-down.

The checked-in scripts do not continuously lower the cap. They only provide the final `setAssetCap(M, 0)` operation after the tracked reserve is fully drained.

## 10. Finalize M removal

`ProposeZeroMAssetCap` schedules `USDat.setAssetCap(M_TOKEN, 0)` through the asset-cap timelock. It can be proposed before the drain completes so its 5-day delay matures near the expected completion time.

Before execution:

1. Confirm the operation is ready.
2. Call `claimMYield()` to register outstanding M yield.
3. Replace the newly tracked M with PYUSDX.
4. Confirm `assetBalanceOf(M_TOKEN) == 0` again.
5. Execute as soon as operationally practical.

`ExecuteZeroMAssetCap` refuses to execute while tracked M backing is nonzero. It also reports any actual M still held by the proxy, because setting the cap to zero disables both `replaceAsset` and `claimMYield` for M. Since M remains earning, additional yield can accrue between the last claim/replacement and final execution; operators must minimize and explicitly assess that residual amount.

After execution:

- `assetCap(M_TOKEN) == 0`;
- `isAllowedAsset(M_TOKEN) == false`;
- M wraps are disabled;
- M `replaceAsset` is disabled; and
- `claimMYield()` is disabled.

## 11. Post-operation verification

Verify the following against the proxy:

- the ERC-1967 implementation is the intended implementation;
- `pyusdx()` equals `0xeBDB0942cE16386Ab90718C7BD10C91CDb66b14d`;
- `swapFacility()` equals `0x0bC305e7e13113cAEd3f5486849e9518a1cC4173`;
- `M_TOKEN()` equals `0x866A2BF4E572CbcF37D5071A7a58503Bfb36be1b`;
- holder balances and `totalSupply` were preserved except for the surplus minted by `migrate()`;
- legacy alternative-asset balances were preserved;
- `assetCap(M)` and `assetBalanceOf(M)` match the expected migration stage;
- `M.isEarning(USDat)` remains true until an explicitly authorized external change says otherwise;
- all pre-upgrade AccessControl roles remain assigned to the expected holders;
- `migrate()` cannot be called a second time;
- `pinVersion()` and `unpinVersion()` revert with `VersionPinningDisabled`;
- the `replaceAsset` caller whitelist matches the intended policy;
- USDat is approved by the PYUSDX extension registry; and
- PYUSDX earner configuration matches the intended rate, fee, and claim recipient.

The fork suite exercises the implemented timelock upgrade, migration accounting, ongoing M yield, holder and role preservation, replace-asset whitelist, M-cap finalizer, and deployed implementation code hash:

```bash
MAINNET_RPC_URL=<rpc-url> \
  forge test --match-contract UpgradeUSDatForkTest -vvv
```

## 12. Required records

For each production operation retain:

- source commit;
- implementation address and runtime code hash;
- proposal and execution transaction hashes;
- timelock operation ID;
- pre- and post-operation accounting snapshots;
- role-holder confirmations;
- PYUSDX extension and earner configuration; and
- M reserve, tracked balance, cap, and unclaimed-yield values at finalization.
