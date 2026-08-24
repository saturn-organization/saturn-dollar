# USDat → PYUSDX Migration — Approach A (Inherit MultiMint)

**Date:** 2026-06-05
**Status:** Verified draft (all PYUSDX-side claims checked against `m0-foundation/PYUSDX@main`)
**Supersedes:** the Approach A section of `plans/usdat-multimint-migration.md`
**Branch:** `proto-963-migrate-usdat-code-to-pyusdx`

---

## 0. What changed after verification

I read the actual PYUSDX source (`MultiMint.sol`, `YieldToOne.sol`, `Extension.sol`,
`SwapFacility.sol`, `ExtensionFactory.sol`, `IPYUSDX.sol`) plus the current USDat stack.
The original plan was directionally right but understated the work. **It is not a
"2 one-liner PR".** Confirmed facts and corrections:

| # | Finding | Impact on plan |
|---|---------|----------------|
| 1 | MultiMint lives in the **`m0-foundation/PYUSDX`** repo — a *different* repo from the public `evm-m-extensions` that `lib/m-extensions` currently points at. (Verified: no branch of `evm-m-extensions` contains `MultiMint`/`src/platform/`; PYUSDX nests `evm-m-extensions` as a sub-lib.) PYUSDX compiles at **Solidity 0.8.34 / evm_version cancun / optimizer_runs 2933 / no via_ir**. | **Re-point** the existing `lib/m-extensions` submodule URL to `m0-foundation/PYUSDX` (§3). saturn-dollar is `0.8.26 / via_ir / runs 200` → **project-wide compiler bump required.** Affects `VerifyCodeHash.s.sol`. |
| 2 | `MultiMintStorageLayout._getMultiMintStorage()` and `YieldToOneStorageLayout._getYieldToOneStorage()` are `internal pure` — **not virtual**. | The 2-line PYUSDX PR (make them `virtual`) is **genuinely required** and is the crux of Approach A. No alternative — mappings can't be slot-migrated in `migrate()`. |
| 3 | Storage structs are layout-compatible (verified field-for-field). | Override-to-legacy-slot trick is sound. See §2. |
| 4 | `ForcedTransferable` is not in PYUSDX's `src/`, but ships in the vendored `evm-m-extensions` (`@0f46bc22`) where it uses `pragma solidity ^0.8.26` (caret) → compiles at 0.8.34. | **Import from the vendored path — no copy needed.** Only `_forceTransfer` needs `_revertIfInvalidRecipient` → `_revertIfZeroAccount`. |
| 5 | **SwapFacility gates every swap on `ExtensionFactory.isApprovedExtension(extension)`.** | USDat **must** be registered via `ExtensionFactory.registerExtension(USDat, MULTI_MINT)` by a `FACTORY_MANAGER_ROLE` holder. **Hard launch dependency, not optional.** |
| 6 | `registerExtension` accepts **any external address** if `IExtension(ext).pyusdx()==pyusdx && .swapFacility()==swapFacility`. | USDat can stay a **TransparentUpgradeableProxy** — it does NOT need factory/beacon deployment. Interop is unblocked. |
| 7 | `Extension` beacon/version machinery shares the **ERC-1967 impl slot** with TransparentProxy; USDat's origin beacon is never set, so `pinVersion` reverts and `unpinVersion` is a recoverable DoS — `VERSION_MANAGER_ROLE` is useless. | Make pin/unpin `virtual` upstream and **override both in USDat to revert** (§5). `migrate` takes no `versionManager` (role unused). |
| 8 | PYUSDX `YieldToOne._beforeClaimYield()` is `onlyRole(YIELD_RECIPIENT_MANAGER_ROLE)`. | **`claimYield()` becomes permissioned** (was permissionless on M). Do the pre-migration M-yield claim *before* upgrade. |
| 9 | `Extension` renamed `_revertIfInvalidRecipient` → `_revertIfZeroAccount`. | USDat's `_forceTransfer` override needs that one rename. |
| 10 | `unwrap(address,uint256)` → `unwrap(uint256)`; yield is `_excess() + accruedYieldToSelfOf`. | Inherited cleanly by Approach A. Deployed SwapFacility must be the PYUSDX one. |

**Verdict:** Approach A is viable and produces the cleanest USDat, but it is a
medium-sized integration (compiler bump + dependency re-vendoring + 1 PYUSDX PR +
factory registration), not a trivial swap.

---

## 1. Current vs target inheritance

```
CURRENT (M-backed, solc 0.8.26)
USDat → JMIExtension → MYieldToOne → MExtension → ERC20ExtendedUpgradeable
      → ForcedTransferable
      slots: M0.storage.JMIExtension 0x4717…4b00, M0.storage.MYieldToOne 0xee2f…f100

TARGET (PYUSDX-backed, solc 0.8.34)
USDat → MultiMint → YieldToOne → Extension → ERC20ExtendedUpgradeable
      → ForcedTransferable (from vendored evm-m-extensions, ^0.8.26)
      slots overridden back to legacy 0x4717…4b00 / 0xee2f…f100
```

---

## 2. Storage compatibility (verified)

Both divergent structs are layout-compatible, so pointing the PYUSDX accessors at the
**legacy** ERC-7201 slots preserves every existing value with zero migration of contents.

```
YieldToOne (PYUSDX)            == MYieldToOne (M)            → IDENTICAL
{ uint256 totalSupply, address yieldRecipient, mapping(address=>uint256) balanceOf }

MultiMint.MultiMintStorage     ⊃ JMIExtensionStorageStruct  → APPEND-ONLY
M:      { mapping assets, uint256 totalAssets }
PYUSDX: { mapping assets, uint256 totalAssets, EnumerableSet replaceAssetWhitelist }
Asset { uint256 cap; uint240 balance; uint8 decimals } → identical in both
```

- Legacy JMI slot used offsets +0 (mapping base) and +1 (`totalAssets`). The new
  `replaceAssetWhitelist` lands at **+2**, which was previously unwritten → reads as
  empty. ✓ Safe.
- All other components are the **same source** (`evm-m-extensions` components) and use
  hardcoded keccak namespaces, so their slots are identical regardless of which copy is
  compiled: `M0.storage.Freezable 0x2fd5…ce00`, `ERC20Extended 0xcbbe…a100`,
  `Pausable 0xcd5e…0300`, `AccessControl 0x02dd…6800`. USDat's own
  `Saturn.storage.Whitelist 0x1d6c…1000` is unchanged. ✓

**Required PYUSDX PR (the linchpin):**
```solidity
// src/platform/projects/MultiMint.sol
function _getMultiMintStorage() internal pure virtual returns (MultiMintStorage storage $) { … }
// src/platform/projects/YieldToOne.sol
function _getYieldToOneStorage() internal pure virtual returns (YieldToOneStorage storage $) { … }
```

**USDat overrides (point inherited logic at legacy slots):**
```solidity
function _getMultiMintStorage() internal pure override returns (MultiMintStorage storage $) {
    bytes32 location = 0x4717d46f2e033163981fa31651301a35281b6b08316965d315fd1577bad94b00;
    assembly { $.slot := location }
}
function _getYieldToOneStorage() internal pure override returns (YieldToOneStorage storage $) {
    bytes32 location = 0xee2f6fc7e2e5879b17985791e0d12536cba689bda43c77b8911497248f4af100;
    assembly { $.slot := location }
}
```

---

## 3. Dependency & toolchain work (new — not in original plan)

1. **Re-point the existing submodule.** In `.gitmodules`, change the `lib/m-extensions`
   URL from `m0-foundation/evm-m-extensions` to `m0-foundation/PYUSDX`, and bump to a ref
   containing `src/platform/projects/MultiMint.sol`. PYUSDX transitively provides
   `lib/evm-m-extensions` + `lib/common` under that path. Update `remappings.txt`
   (e.g. `@pyusdx/=lib/m-extensions/src/`, and remap the nested
   `@m-extensions/=lib/m-extensions/lib/evm-m-extensions/src/` if any `src/` import still needs it).
   Run `git submodule sync && git submodule update --init`.
2. **Single source for shared components.** Because PYUSDX nests its own
   `evm-m-extensions`, import all shared components (`Freezable`/`Pausable`/`ERC20Extended`)
   **only** through PYUSDX's nested copy — never a second standalone `evm-m-extensions` —
   to avoid two incompatible copies of the same *type* (storage slots are identical via
   keccak namespaces; Solidity type identity is not). Audit `USDat.sol`/scripts for any
   lingering `@m-extensions/...` import that resolves to the old M-backed tree.
3. **Bump `foundry.toml`** to `solc_version = "0.8.34"`, `evm_version = "cancun"`. Decide on
   `via_ir`/optimizer settings — PYUSDX uses `runs = 2933`, no `via_ir`. Align to keep
   bytecode reproducible for `VerifyCodeHash.s.sol`.
4. **`ForcedTransferable` — no copy needed.** Import directly from the vendored
   `evm-m-extensions` (`src/components/forcedTransferable/ForcedTransferable.sol`, `^0.8.26`
   → compiles at 0.8.34). Just add a remapping.

---

## 4. USDat source changes

```solidity
// pragma solidity 0.8.34;
contract USDat is IUSDat, MultiMint, ForcedTransferable {
    constructor(address pyusdx_, address swapFacility_) MultiMint(pyusdx_, swapFacility_) {}

    // initialize(...) → __MultiMint_init(name, symbol, yieldRecipient, admin,
    //     assetCapManager, freezeManager, pauser, yieldRecipientManager, versionManager)
    //   NOTE new required arg: versionManager (see §5 footgun — pass the secure admin/timelock)
    //   then __ForcedTransferable_init(compliance); _grantRole(WHITELIST_MANAGER_ROLE, compliance);

    // §2 storage-slot overrides

    // Whitelist hooks: keep _beforeWrap(account,recipient,amount),
    //   _beforeWrap(asset,account,recipient,amount), _beforeUnwrap(account,amount) as-is
    //   (signatures match PYUSDX Extension/MultiMint; they call super.* → pause+freeze).

    // _forceTransfer: identical EXCEPT _revertIfInvalidRecipient → _revertIfZeroAccount.
}
```

`IUSDat.sol`: extend/realign to `IMultiMint` surface; add `migrate(...)`; drop
`IJMIExtension`-specific signatures. Keep the whitelist event/error/function set unchanged.

Behavioral deltas inherited (document for compliance/integrators):
- `claimYield()` is now **permissioned** (`YIELD_RECIPIENT_MANAGER_ROLE`).
- `setYieldRecipient` claims yield first, and **skips the claim if the outgoing recipient is frozen**.
- `_freeze`/`_unfreeze` semantics follow PYUSDX components (silent no-op vs M's revert).
- alt-asset extraction is `replaceAsset` (+ optional caller whitelist) instead of `replaceAssetWithM`.

---

## 5. The TransparentProxy × Extension-versioning footgun (must mitigate)

`Extension` was designed for an `ExtensionBeaconProxy`, where the impl is resolved via the
**beacon** and the ERC-1967 `_IMPLEMENTATION_SLOT` is free, used only as an optional "pin"
override. USDat instead sits behind a **TransparentUpgradeableProxy**, where that same slot
is the *live* implementation pointer. Consequences:
- `pinnedImplementation()` returns the live implementation; `isPinned()` returns `true`
  (cosmetic; can confuse explorers).
- `pinVersion(v)` reads `originBeacon` (empty `_ORIGIN_BEACON_SLOT`) and calls
  `implementation(v)` on `address(0)` → **reverts**. Harmless but dead.
- **`unpinVersion()` passes its `!= 0` guard, then zeroes `_IMPLEMENTATION_SLOT`.** Every
  subsequent non-admin call `delegatecall`s `0x0` → **full DoS**. It is
  `onlyRole(VERSION_MANAGER_ROLE)`.

**Severity:** DoS, **not** a permanent brick or fund loss. The ERC-1967 *admin* slot is a
different slot and is untouched; admin calls are handled by the proxy (not delegated), so
`ProxyAdmin.upgradeAndCall(proxy, impl, "")` rewrites the impl slot and restores service.

**Mitigation (DECIDED):** `pinVersion`/`unpinVersion` are **not `virtual` upstream**, so they're made
`virtual` in PYUSDX `Extension` (a 2nd one-liner pair alongside the storage-accessor change on `proto-962`)
and **overridden in `USDat.sol` to `revert VersionPinningDisabled()`**. That permanently neutralizes both,
regardless of role holder. `VERSION_MANAGER_ROLE` is then irrelevant — **`migrate` takes no `versionManager`
param and never grants the role** (no holder on the live proxy); a fresh `__YieldToOne_init` (test harness
only) requires a non-zero but it's inert. Unit test: both functions revert for everyone (incl. a role holder); `unpinVersion()` cannot
zero `_IMPLEMENTATION_SLOT`. See `usdat-migration-m-as-replaceable-asset.md` §3.

---

## 6. SwapFacility interop (hard dependency)

`SwapFacility.swapIn/swapOut/_replaceAsset` all call `_revertIfNotApprovedExtension` →
`ExtensionFactory.isApprovedExtension(USDat)`. Approval requires a `FACTORY_MANAGER_ROLE`
holder to call:
```solidity
ExtensionFactory.registerExtension(USDat_proxy, ExtensionType.MULTI_MINT);
```
which succeeds iff `USDat.pyusdx() == factory.pyusdx()` and
`USDat.swapFacility() == factory.swapFacility()`. **Therefore USDat's constructor
immutables must be the exact PYUSDX + PYUSDX-SwapFacility addresses for the target chain.**
Without this registration, all wrap/unwrap via SwapFacility revert.

---

## 7. Migration sequence (Transparent proxy, `ProxyAdmin.upgradeAndCall`)

**Pre-upgrade (while still M-backed / claimYield still permissionless):**
1. `claimYield()` on current USDat — realize all pending M yield.
2. `pause()`.
3. Treasury acquires PYUSDX, amount = `M.balanceOf(USDat_proxy)` (1:1 value assumed);
   `PYUSDX.approve(USDat_proxy, amount)`.

**CI gate — fork test (required):**
- `vm.load()` every preserved slot before/after upgrade: `totalSupply`, `yieldRecipient`,
  a sample of holder balances, `totalAssets`, asset caps/balances/decimals — assert unchanged.
- Cross-check with OZ Upgrades storage-layout diff.

**Atomic upgrade:**
1. Deploy new `USDat(pyusdx, pyusdxSwapFacility)` implementation (solc 0.8.34/cancun).
2. `ProxyAdmin.upgradeAndCall(proxy, newImpl, abi.encodeCall(USDat.migrate, (treasury, oldMToken)))`.
   `migrate` is a `reinitializer(2)` that: grants `VERSION_MANAGER_ROLE` (to secure admin),
   pulls PYUSDX `transferFrom(treasury, this, totalSupply())`, pushes residual M to treasury,
   and asserts `PYUSDX.balanceOf(this) >= totalSupply()`. Guard with an `AlreadyMigrated` flag.

**Post-upgrade:**
1. `ExtensionFactory.registerExtension(USDat, MULTI_MINT)` — `FACTORY_MANAGER_ROLE` (§6).
2. PYUSDX earner manager configures USDat as an earner (so `accruedYieldToSelfOf` accrues).
3. Point integrations at the PYUSDX SwapFacility; `unpause()`.

---

## 8. Files to change

- `foundry.toml` — solc 0.8.34, evm cancun, optimizer/via_ir alignment.
- `.gitmodules` / `remappings.txt` — re-point `lib/m-extensions` URL to `m0-foundation/PYUSDX`, bump ref, fix remappings; resolve evm-m-extensions duplication.
- `src/USDat.sol` — re-inherit `MultiMint`; 2 storage overrides; new `initialize` arg
  (`versionManager`); `_forceTransfer` rename; add `migrate()`; optional pin/unpin disable.
- `src/IUSDat.sol` — realign to `IMultiMint`; add `migrate()`.
- (No new `ForcedTransferable` file — imported from the vendored `evm-m-extensions`, `^0.8.26`.)
- `script/UpgradeUSDat.s.sol` — constructor args = (pyusdx, pyusdxSwapFacility); add
  `migrate` calldata; add post-upgrade `registerExtension` step (separate tx / runbook).
- `script/PYUSDx_Deployment_Scripts/VerifyCodeHash.s.sol` — re-baseline for new compiler.
- PYUSDX repo PR — make the two storage accessors `virtual` **and** `Extension.pinVersion`/`unpinVersion` `virtual`.

---

## 9. Open questions (updated)

1. PYUSDX `virtual` changes: storage accessors are done on `proto-962-make-storage-locations-accessors-virtual` (`@59389a3`); **still need to add `virtual` to `Extension.pinVersion`/`unpinVersion`** on that branch.
2. ~~Land `ForcedTransferable` in PYUSDX, or vendor a copy?~~ — RESOLVED: imported from vendored `evm-m-extensions` (`^0.8.26`), no copy needed.
3. Who holds `FACTORY_MANAGER_ROLE` on the target chain, and what is the registration runbook/timing relative to unpause?
4. ~~Who holds `VERSION_MANAGER_ROLE`?~~ — RESOLVED: pin/unpin overridden to revert (needs upstream `virtual`); role unused, `migrate` passes `address(0)` (§5).
5. Confirm PYUSDX + SwapFacility + ExtensionFactory addresses per target chain (immutables must match).
6. Earner-manager pre-approval: must USDat be set as earner before or after unpause?
7. Accept the `claimYield` permissioning + freeze-skip-claim behavior changes?
8. Reproducible-build policy: align optimizer settings so `VerifyCodeHash` stays meaningful.

---

## 10. As-built deltas (implementation, 2026-06-05)

Three deviations from the plan surfaced while implementing and are now reflected in `src/USDat.sol`:

1. **`pinVersion`/`unpinVersion` are not `virtual` upstream** → make them `virtual` in PYUSDX `Extension`
   (2nd one-liner pair on `proto-962`) and **override both in USDat to `revert VersionPinningDisabled()`**.
   On USDat's transparent proxy the origin beacon is never set, so pinning can't work and
   `VERSION_MANAGER_ROLE` is useless; the override neutralizes both functions permanently. `migrate` takes no
   `versionManager` param and never grants the role (no holder on the live proxy). See
   `usdat-migration-m-as-replaceable-asset.md` §3. (Supersedes the earlier "grant to admin" / "pass address(0)" ideas.)
2. **`IMTokenLike` is pinned to exact `=0.8.26`** → cannot be imported under 0.8.34. `migrate` uses OZ's
   `IERC20` (`openzeppelin-contracts/contracts/token/ERC20/IERC20.sol`, `^0.8.20`) for the PYUSDX pull and
   legacy-M return instead.
3. **Error-name diamond clash:** both `IMultiMint` and `IForcedTransferable` declare
   `error ArrayLengthMismatch()`. Inheriting both is a compile error, so the (tiny) `ForcedTransferable`
   component is **inlined into `USDat`** (role + `forceTransfer`/`forceTransfers` + `_forceTransfer`),
   reusing the inherited `IMultiMint.ArrayLengthMismatch`. The `ForcedTransfer` event and
   `ZeroForcedTransferManager` error moved to `IUSDat`.

`migrate(treasury, oldMToken, versionManager)` gained the `versionManager` param (the `initialize` grant
is skipped on upgrade) and asserts the pulled PYUSDX covers `totalSupply - totalAssets` via the inherited
`InsufficientPYUSDXBacking`.

**Status:** `src/USDat.sol` + `src/IUSDat.sol` rewritten; `test/USDat.t.sol` green (16 tests:
initialize/roles, wrap/unwrap, whitelist gating, forced transfer, `claimYield` permissioning + accrual,
pin/unpin role-gating, `migrate`). Full project builds under 0.8.34/cancun.

**Still TODO:** mainnet-fork storage-preservation test (needs `MAINNET_RPC_URL` + live proxy); alt-asset
wrap + `replaceAsset` + asset-cap tests; mutation testing; deploy/upgrade script updates (`migrate`
calldata + `registerExtension` runbook); sync Notion §5 with delta #1.
```
