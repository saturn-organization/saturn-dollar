# USDat Migration v2 — register M as a replaceable alt-asset

**Date:** 2026-06-08
**Status:** Plan (supersedes the `migrate()` reserve-swap design in `usdat-pyusdx-approach-a.md` §7 and `src/USDat.sol`)
**Scope:** Change `migrate()` so the existing **M reserves are carried over as a MultiMint alt-asset** and converted to PYUSDX over time via `replaceAsset`, instead of the treasury fronting all PYUSDX atomically at upgrade.

---

## 1. Why

The current `migrate()` pulls `totalSupply - totalAssets` PYUSDX from a treasury in one shot and
pushes the M out. That needs the treasury to source the **entire** PYUSDX backing up front.

MultiMint already models exactly what we want: an alt-asset held in reserve that can be swapped out
for PYUSDX via `replaceAsset(asset, recipient, amount)` (caller deposits PYUSDX, receives the alt-asset).
So we register the legacy **M as an alt-asset**, and the M→PYUSDX conversion happens incrementally and
market-/treasury-driven, with **zero up-front PYUSDX**.

---

## 2. Accounting model (verified against `MultiMint.sol`)

MultiMint backing split:

```
_pyusdxBacking() = totalSupply > totalAssets ? totalSupply - totalAssets : 0  // clamped ≥ 0
assets[a].balance (asset decimals)                  // portion held as alt-asset `a`
totalAssets (6-dec)                                 // Σ alt-asset backings in extension decimals
```

M is 6-decimals (== extension decimals), so M-amount ≡ extension-amount 1:1.

**At migrate** (pre-state: JMIExtension, fully M-backed after a pre-upgrade `claimYield`):

- `mBalance := IERC20(M).balanceOf(this)` — the M reserves the contract holds (== the M-backed portion
  `totalSupply − totalAssets` once the pre-upgrade `claimYield` has realized M yield).
- Register `assets[M] = { cap: mBalance, balance: uint240(mBalance), decimals: 6 }`.
- `totalAssets += mBalance`.

Result: the `migrate` guard ensures `mBalance == totalSupply − totalAssets`, so after `totalAssets += mBalance`
we have `totalAssets == totalSupply` exactly and `_pyusdxBacking() == 0` — no PYUSDX needed at upgrade. The
contract's backing is entirely alt-assets (pre-existing alts + M). (Over-backing, `totalAssets > totalSupply`,
is **not** acceptable — it breaks `_excess()`/`claimYield`; the guard prevents it. See §3.)

**Each `replaceAsset(M, recipient, amount)`** (verified at `MultiMint.sol:327`):

- pulls `amount` PYUSDX, sends `amount` M (1:1), `assets[M].balance -= amount`, `totalAssets -= amount`.
- ⇒ `_pyusdxBacking()` grows by `amount`; PYUSDX reserves grow by `amount`.

When M is fully drained: `assets[M].balance == 0`, `totalAssets` back to its pre-migrate value, and the
PYUSDX reserves equal the original M-backed portion. Migration complete, no atomic treasury outlay.

---

## 3. `migrate()` redesign

`migrate` registers the **M balance the contract holds** as a replaceable alt-asset and adds it to
`totalAssets`. It also **stops M earning itself** via the M token's no-arg `stopEarning()` (self opt-out,
§11). M *yield* is realized by the **pre-upgrade `claimYield()`** (§7/§11), so by the time `migrate` runs M is
fully realized; `stopEarning()` then freezes it.
`migrate` does **not** mint or change `totalSupply`.

**Upgrade-only — `migrate` is the *only* entry point; `initialize` is removed.** The live proxy already
consumed `initializer` (v1) at its original JMIExtension deploy (`_initialized == 1`), so `initialize` could
never run on it again anyway. USDat is **not** meant to be freshly deployed — only to upgrade the existing
proxy — so keeping an `initialize` only confuses readers. All roles/state from the JMI init persist in storage
across the upgrade. `migrate` deliberately does **not** re-set base roles / name / `yieldRecipient` — those
already exist on the proxy and may have been re-assigned via role admin since deploy.

**`VERSION_MANAGER_ROLE` is inert — `pinVersion`/`unpinVersion` are overridden to revert.** USDat is a
transparent proxy whose origin beacon (`_ORIGIN_BEACON_SLOT`, written only by `ExtensionBeaconProxy`'s
constructor) is never set. So `pinVersion` always reverts (`IExtensionBeacon(0).implementation(v)` on a
codeless address) and `unpinVersion` would only zero the impl slot (recoverable DoS) — version-pinning is
meaningless here and `VERSION_MANAGER_ROLE` is useless. (Factory registration does **not** change this — it
writes the factory's own storage, not USDat's origin beacon.)

Permanent fix: make `pinVersion`/`unpinVersion` **`virtual`** in PYUSDX `Extension` (a 2nd trivial upstream
change alongside the storage-accessor PR on `proto-962`), and **override both in USDat to
`revert VersionPinningDisabled()`** — neutralized regardless of role holder. `VERSION_MANAGER_ROLE` is then
fully unused: **`migrate` takes no `versionManager` param and never grants it**, so the role simply has no
holder on the live proxy (the JMI init never granted it either). The test-only `USDatHarness.initialize`
passes a non-zero only because `__YieldToOne_init` requires it (inert). `isPinned()`/`pinnedImplementation()`
remain as harmless cosmetic views (no override needed).

> Testing: production USDat exposes only `migrate`, so a fresh test proxy has no base state. Unit tests use a
> test-only `test/USDatHarness.sol` that adds an `initialize` to stand up a working instance. The real
> JMI→`migrate` upgrade path is exercised by the mainnet-fork test (§8). The old JMI USDat can't be deployed
> in tests directly (pinned `0.8.26`, won't compile under 0.8.34).

⚠️ **`migrate` is reinitializer-guarded but NOT role-gated** (under `upgradeAndCall`, `msg.sender` is the
`ProxyAdmin`, which holds no role). It MUST be invoked **atomically** as the `data` arg of
`ProxyAdmin.upgradeAndCall(proxy, newImpl, migrate(...))` (§7). Upgrading the impl in a separate tx from
`migrate` would let anyone front-run it with a malicious `mToken`.

```solidity
function migrate(address mToken) external reinitializer(2) {
    // Freeze the M reserve: self opt-out of earning (USDat is always earning at migrate, so no isEarning
    // guard). The no-arg stopEarning() should be exempt from the IsApprovedEarner revert (which guards only
    // the stopEarning(address) force-stop variant), so it works while USDat is still on the approved-earner
    // list — no governance de-listing. ⚠️ MUST be confirmed on the mainnet fork (see §8 / §11 caveat).
    IMEarner(mToken).stopEarning();

    // Register the M balance held as the replaceable alt-asset and account it in totalAssets.
    uint256 mBalance = IERC20(mToken).balanceOf(address(this));

    // REQUIRED: the pre-upgrade claimYield() must have realized all M yield, so the M held exactly equals
    // the M-backed portion. If not, totalAssets += mBalance would make totalAssets > totalSupply (over-backed):
    // the unrealized yield gets folded into backing (lost to yieldRecipient) and corrupts _excess()/claimYield.
    if (mBalance != totalSupply() - totalAssets()) revert MReservesMismatch(mBalance, totalSupply() - totalAssets());

    MultiMintStorage storage $ = _getMultiMintStorage();      // overridden → legacy JMI slot
    $.assets[mToken] = Asset({ cap: mBalance, balance: UIntMath.safe240(mBalance), decimals: 6 });
    $.totalAssets += mBalance;
}
```

The registered M balance equals the M-backed portion, so after `totalAssets += mBalance` we get
`totalAssets == totalSupply` and `_pyusdxBacking() == 0` — no PYUSDX needed at upgrade. The guard
`mBalance == totalSupply − totalAssets` enforces this.

**`claimYield()` pre-upgrade is REQUIRED** (it realizes the M yield to `yieldRecipient` and makes
`mBalance == totalSupply − totalAssets`). If skipped, the unrealized M yield `Y` would be folded into the
alt-asset backing (`totalAssets = totalSupply + Y > totalSupply`): **`Y` is never paid to `yieldRecipient`
— lost to them** — and the over-backed state violates MultiMint's `totalAssets ≤ totalSupply` invariant,
corrupting `_excess()`/`claimYield` (the clamp masks the surplus, so PYUSDX later deposited via `replaceAsset`
is mis-counted as claimable excess → unbacked USDat minting). The `migrate` guard reverts in that case, so the
whole upgrade fails closed unless `claimYield` ran. Registering the actual M balance keeps
`assets[M].balance == physical M`, so `replaceAsset` drains it with no stranded dust.

Notes / changes from current code:

- **Drops** the `treasury` PYUSDX pull and the M push-out entirely. No PYUSDX moves at upgrade; M stays.
- **Backing guard:** `require(mBalance == totalSupply() - totalAssets())` — enforces that the pre-upgrade
  `claimYield()` ran (no unrealized M yield), preventing the over-backed `totalAssets > totalSupply` state.
  Reverts the upgrade if violated (fail-closed). New error `MReservesMismatch(held, backing)` in `IUSDat`.
- `assets[mToken]` is currently empty (in JMI, M was the _primary_ asset, never in the `assets` mapping),
  so there is no collision. `mToken != pyusdx`, so MultiMint treats it as a valid alt-asset.
- `cap = mBalance` (non-zero ⇒ `isAllowedAsset(M)` true ⇒ `replaceAsset` enabled; `cap == balance` also
  blocks initial M wraps — §4).
- Writes go through the overridden `_getMultiMintStorage()` (legacy JMI slot); `replaceAssetWhitelist`
  lives at slot+2 (previously unused) and is untouched here.
- New imports: `UIntMath` (from the vendored common lib) for `safe240`; a tiny local
  `interface IMEarner { function stopEarning() external; }` — the **no-arg `stopEarning()`** (self opt-out),
  which the evm-m-extensions `IMTokenLike` doesn't expose but the real M token does (`wrapped-m-token`
  `IMTokenLike`/`WrappedMToken` use it). (`IMTokenLike` is `=0.8.26`-pinned anyway, so we use a local
  interface — same reason we use OZ `IERC20`.) Called unconditionally (no `isEarning` guard).
- `migrate` **preserves `totalSupply`** (no mint) — yield realization happens in the pre-upgrade `claimYield()`.
- ⚠️ **Assumption to verify on fork:** the no-arg `stopEarning()` self-call succeeds while USDat is still a
  TTG-approved earner (i.e. it's exempt from `IsApprovedEarner`, which guards the `stopEarning(address)`
  force-stop variant). `WrappedMToken.disableEarning()` defensively `_revertIfApprovedEarner`s before its own
  `stopEarning()` call — likely its own policy, but if the M token *itself* reverts the self-call for approved
  earners, we'd need a governance de-listing step pre-upgrade after all. The fork test is the decider.

---

## 4. Re-wrapping M — no guard needed (DECIDED)

No dedicated wrap-guard or extra storage. M re-wrapping is a non-issue because:

1. `migrate` sets `cap = balance = mBalance`, so `isAllowedToWrap(M, amount)` is already `false`
   (`cap >= balance + amount` fails for any `amount > 0`) — M cannot be wrapped in until `replaceAsset`
   frees headroom.
2. Wraps are gated by USDat's compliance whitelist; only trusted whitelisted callers (treasury/MM) can
   act and they will not wrap M.
3. End of wind-down: `setAssetCap(M, 0)` (by `ASSET_CAP_MANAGER_ROLE`) removes M from allowed assets.

This keeps `migrate` minimal — no `migratedAsset` slot, no `_beforeWrap` override change.

---

## 5. replaceAsset access — whitelisted treasury/MM (DECIDED)

`replaceAsset` is gated by `replaceAssetWhitelist` (empty ⇒ open). We **restrict to treasury/MM**.

Configuration timing avoids any open window: `_replaceAsset` has `_requireNotPaused()`, and USDat is
**paused throughout the upgrade**. So the whitelist is set _before_ unpause:

- Post-`migrate` (still paused): `processor` (`ASSET_CAP_MANAGER_ROLE`) calls
  `setReplaceAssetWhitelistCaller(treasury, true)` (single or batch).
- Then register in `ExtensionFactory`, set earner, and finally `unpause`.

`migrate` itself does **not** touch the whitelist.

---

## 6. Behavioural consequences

- **Unwrap capacity ramps with PYUSDX reserves.** Right after migrate `_pyusdxBacking()=0`, so
  `unwrap` reverts (`InsufficientPYUSDXBacking`) until `replaceAsset` builds PYUSDX reserves. Transfers and
  alt-asset wraps of _other_ assets are unaffected. This is acceptable and self-heals as M is replaced.
- **Yield:** during the M-backed phase the contract holds ~0 PYUSDX, so `yield()=0`; PYUSDX yield begins
  accruing only on PYUSDX reserves as they build. Correct.
- **No treasury pre-funding** and no single-tx PYUSDX requirement.

---

## 7. Migration runbook

Only the **M yield claim** must run pre-upgrade — the canonical M `claimYield()` exists only on the live
JMI impl (`upgradeAndCall` swaps the impl before invoking `migrate` — see §11). **Stopping M earning moves
*into* `migrate`** via the M token's self opt-out `stopEarning()` (no governance de-listing — §11). No M
approved-earner removal is required.

Execute as **one atomic Safe `multiSend` batch**:

1. `usdat.pause()`.
2. `usdat.claimYield()` — canonical M-yield realization (live JMI, permissionless). **Required** — `migrate`
   reverts (`MReservesMismatch`) if unrealized M yield remains.
3. `ProxyAdmin.upgradeAndCall(proxy, newImpl, migrate(mToken))` — self-stops M earning (`stopEarning()`)
   and registers M as the replaceable alt-asset (`mBalance == backing` after the claim).
4. Still paused: configure `replaceAssetWhitelist` (treasury/MM) via `processor`
   (`ASSET_CAP_MANAGER_ROLE`); register USDat in `ExtensionFactory` (required for SwapFacility);
   set USDat as a PYUSDX earner.
5. `usdat.unpause()`.
6. (End of wind-down) once `assetBalanceOf(M) == 0`, `setAssetCap(M, 0)` to de-register M.

---

## 8. Test plan (replaces the two current `migrate` tests)

Unit (mock harness — note full M-backed pre-state fidelity is the fork test):

- `migrate` registers M: `assetCap(M)==mBalance`, `assetBalanceOf(M)==mBalance`, `assetDecimals(M)==6`,
  `totalAssets` bumped by `mBalance`, `_pyusdxBacking()==0`, **once-only** (reinitializer). `migrate` does
  not touch `VERSION_MANAGER_ROLE`.
- `migrate` **preserves** `totalSupply` and holder balances (no mint).
- `migrate` self-stops M earning via no-arg `stopEarning()` (called unconditionally — USDat is earning at
  migrate; mock M earner).
- `migrate` **reverts `MReservesMismatch`** when `mBalance != totalSupply − totalAssets` (i.e. `claimYield`
  was skipped / unrealized M yield present) — fail-closed against the over-backed state.
- `replaceAsset(M)` drain: whitelisted caller deposits PYUSDX → receives M; `assetBalanceOf(M)` and
  `totalAssets` decrease by the amount; `_pyusdxBacking()` (and unwrap capacity) increase.
- Wrapping M is blocked initially by the cap (`cap==balance`); wrapping other assets / PYUSDX still works.
  After a full drain, `setAssetCap(M, 0)` de-registers M.
- `unwrap` reverts immediately post-migrate (backing 0), then succeeds up to the replaced amount.
- Full drain: replace all M ⇒ `assetBalanceOf(M)==0`, `totalAssets` back to baseline.
- `pinVersion`/`unpinVersion` revert `VersionPinningDisabled` for **everyone** — including a
  `VERSION_MANAGER_ROLE` holder (it's the override, not the role check).

Mainnet-fork (the authoritative test): on a real pre-upgrade USDat proxy (kept on the M approved-earner list,
to prove no de-listing is needed), run the §7 batch — `claimYield()` → `upgradeAndCall(migrate)`.
Assert: `claimYield` raised `totalSupply`/`yieldRecipient` by the realized M yield and left
`mBalance == backing`; **`migrate`'s self `stopEarning()` succeeds despite USDat being approved** (the key
assumption — if this reverts, a governance de-listing step is needed pre-upgrade); `migrate`
**preserves** `totalSupply`, `yieldRecipient`, holder balances and existing asset caps/balances
(`vm.load`/getters); M earning is stopped; `assets[M]` registered at the full M balance with
`_pyusdxBacking()==0`; and `replaceAsset` drains M ↔ PYUSDX correctly.

---

## 9. Files to change

- `src/USDat.sol` — **remove `initialize`** (upgrade-only contract); `migrate(address mToken)` is the sole
  entry point: self-stop M earning via no-arg `stopEarning()` (called unconditionally) + **backing guard
  `require(mBalance == totalSupply() - totalAssets())`** + register the M balance held as the replaceable
  alt-asset. **Override `pinVersion`/`unpinVersion` to `revert VersionPinningDisabled()`** (no
  `VERSION_MANAGER_ROLE` grant anywhere). Add `UIntMath` import + `Asset` usage + a local `IMEarner` interface
  (with the no-arg `stopEarning()`). No mint, no new storage, no `_beforeWrap` change.
- `src/IUSDat.sol` — `migrate` signature (remove treasury param); drop `initialize` from the interface if
  present; add `error VersionPinningDisabled()` and `error MReservesMismatch(uint256 held, uint256 backing)`.
- **PYUSDX upstream** — add `virtual` to `Extension.pinVersion` / `Extension.unpinVersion` (2nd one-liner
  pair alongside the storage-accessor change on branch `proto-962`).
- `test/USDatHarness.sol` (**new, test-only**) — extends USDat, adds an `initialize` (initializer) replicating
  the base setup so unit tests can stand up an instance.
- `test/USDat.t.sol` — deploy via `USDatHarness`; replace the two `migrate` tests per §8; add `replaceAsset`/
  drain tests.
- `script/USDat.s.sol` (fresh-deploy script) — **obsolete** (no fresh deploys); remove or archive.
- `script/UpgradeUSDat.s.sol` — build the §7 atomic batch: call `claimYield()` on the live proxy (via a tiny
  local `interface IUSDatLegacy { function claimYield() external returns (uint256); }` — the canonical
  `0.8.26`-pinned interface can't be imported under 0.8.34), then
  `ProxyAdmin.upgradeAndCall(proxy, newImpl, migrate(mToken))` (`migrate` self-stops M earning); document the
  post-upgrade whitelist/register/earner steps. No M approved-earner removal needed.
- Docs: update `usdat-pyusdx-approach-a.md` §7 + Notion §5 (no atomic PYUSDX outlay; new pre-migration steps).

---

## 10. Open questions

1. ~~replaceAsset access~~ — DECIDED: **whitelisted treasury/MM** (§5).
2. ~~Block M re-wrap?~~ — DECIDED: **no guard**; cap mechanics + compliance whitelist + final `setAssetCap(M,0)` (§4).
3. **M asset cap:** `cap = mBalance` (also blocks initial wraps). Confirm vs a larger cap.
4. Confirm the **mainnet M token address** (`mToken`) and that it is 6-decimals.
5. ~~Set whitelist inline in `migrate`?~~ — DECIDED: **no**; configured post-`migrate` while paused (§5).

---

## 11. Investigation — can the canonical M `claimYield()` run inside `migrate`? No.

`ProxyAdmin.upgradeAndCall` → proxy `upgradeToAndCall` → `ERC1967Utils.upgradeToAndCall` **sets the new
implementation first, then delegatecalls the init data**:
```
68  _setImplementation(newImplementation);
72  Address.functionDelegateCall(newImplementation, data);   // migrate() runs as MultiMint
```
So `migrate` executes on the **new** MultiMint impl — the JMI `claimYield()` no longer exists, and the new
`claimYield()` claims *PYUSDX* yield (wrong asset). ⇒ the canonical M `claimYield()` must run **pre-upgrade**
on the live JMI proxy, batched ahead of `upgradeAndCall` (§7).

**Stopping M earning, however, moves *into* `migrate`.** The M token exposes a **no-arg `stopEarning()`**
(self opt-out — present in `wrapped-m-token`'s `IMTokenLike`, used by `WrappedMToken`), distinct from the
`stopEarning(address)` force-stop variant (used by `MExtension.disableEarning`) which reverts `IsApprovedEarner`
for a still-approved account. Since `migrate` runs in the proxy's context, USDat calls `stopEarning()` on
itself — **expected** to work while still on the approved-earner list, so no governance de-listing / no
pre-upgrade `disableEarning()` step.

⚠️ **Caveat (verify on fork):** `WrappedMToken.disableEarning()` calls `_revertIfApprovedEarner(address(this))`
*before* its no-arg `stopEarning()`. This is likely WrappedMToken's own policy (an approved earner shouldn't
self-disable), implying the M token's no-arg `stopEarning()` is itself self-allowed — but it could instead mean
the M token reverts the self-call for approved earners. If the latter, `migrate`'s `stopEarning()` reverts and
we must add a governance de-listing step pre-upgrade. The mainnet-fork test (§8) is the decider.

**Re-pointing `lib/m-extensions` → PYUSDX is not a problem and need not be reverted.** The on-chain upgrade
runs the already-deployed JMI bytecode regardless of what's vendored; the script only needs the `claimYield()`
selector to call the live proxy, via a 3-line local interface (the canonical `IMYieldToOne` is pinned to
exact `0.8.26` and can't be imported under 0.8.34 anyway).
