# USDat Migration Plan: JMIExtension → MultiMint

**Date:** 2026-06-05  
**Status:** Draft  
**Scope:** Migrate `USDat.sol` from `JMIExtension` (M-backed) to `MultiMint` (PYUSDX-backed)

---

## 1. Context

### Current state

```
USDat → JMIExtension → MYieldToOne → MExtension → ERC20ExtendedUpgradeable
       → ForcedTransferable
```

JMIExtension uses **M** as the uncapped primary asset and allows additional alt-assets up to a cap.

### Target state

```
USDat → MultiMint → YieldToOne → Extension → ERC20ExtendedUpgradeable
       → ForcedTransferable
```

MultiMint uses **PYUSDX** as its primary asset (wrappable via `Extension.wrap(recipient, amount)`) and allows alt-assets up to a cap (via `MultiMint.wrap(asset, recipient, amount)`). This is fully symmetric with JMIExtension, where M is the primary asset.

### Key semantic change

| | JMIExtension | MultiMint |
|---|---|---|
| Primary asset | M — `wrap(recipient, amount)` (uncapped) | PYUSDX — `wrap(recipient, amount)` (uncapped) |
| Alt-asset wrap | `wrap(asset, recipient, amount)`, capped | `wrap(asset, recipient, amount)`, capped |
| `_revertIfInvalidAsset` | blocks M from alt-asset path | blocks PYUSDX from alt-asset path |
| Unwrap receives | M | PYUSDX |
| Yield mechanism | M rebasing (`balanceOf` grows) | PYUSDX non-rebasing (`claimFor` required) |
| Replace function | `replaceAssetWithM` | `replaceAsset` (+ optional caller whitelist) |

---

## 2. Storage Slot Analysis

This is the critical risk surface for any upgrade.

| Storage namespace | Slot (current) | Slot (PYUSDX) | Compatible? |
|---|---|---|---|
| `M0.storage.MYieldToOne` | `0xee2f...f100` | — | **Must preserve** |
| `PYUSDX.storage.YieldToOne` | — | `0xdeb0...2e00` | Different slot |
| `M0.storage.JMIExtension` | `0x4717...4b00` | — | **Must preserve** |
| `PYUSDX.storage.MultiMint` | — | `0x57e1...3f00` | Different slot |
| `M0.storage.Freezable` | `0x2fd5...ce00` | `0x2fd5...ce00` | ✓ Same |
| `M0.storage.ERC20Extended` | `0xcbbe...a100` | `0xcbbe...a100` | ✓ Same |
| `openzeppelin.storage.Pausable` | `0xcd5e...0300` | `0xcd5e...0300` | ✓ Same |
| `openzeppelin.storage.AccessControl` | `0x02dd...6800` | `0x02dd...6800` | ✓ Same |
| `Saturn.storage.Whitelist` | `0x1d6c...1000` | — (USDat-specific) | ✓ Unchanged |
| `ForcedTransferable` | same component | same component | ✓ Same |

The two critical slots that diverge are the YieldToOne and JMI/MultiMint storage. The choice of approach determines how these are handled.

### Struct layout compatibility (relevant to Approach A)

Both pairs are layout-compatible:

```
// MYieldToOneStorageStruct == YieldToOneStorage (field-for-field identical)
{ uint256 totalSupply, address yieldRecipient, mapping(address => uint256) balanceOf }

// JMIExtension.Asset == MultiMint.Asset (field-for-field identical)
{ uint256 cap, uint240 balance, uint8 decimals }

// JMIExtension storage ⊂ MultiMint storage (append-only, backward compatible)
JMIExtension: { mapping assets, uint256 totalAssets }
MultiMint:    { mapping assets, uint256 totalAssets, EnumerableSet replaceAssetWhitelist }
// → replaceAssetWhitelist starts empty; existing data valid
```

---

## 3. Approaches

### Approach A — Inherit MultiMint directly (clean, requires PYUSDX PR)

Switch inheritance from `JMIExtension` to `MultiMint`. Override the two divergent storage accessors to point at the legacy M slots. Struct layouts are compatible (verified above).

**PYUSDX repo changes required (2 one-liners):**
1. `MultiMintStorageLayout._getMultiMintStorage()` → make `virtual`
2. `YieldToOneStorageLayout._getYieldToOneStorage()` → make `virtual`

**USDat changes:**

```solidity
// New inheritance
contract USDat is IUSDat, MultiMint, ForcedTransferable { ... }

// Constructor
constructor(address pyusdx_, address swapFacility_) MultiMint(pyusdx_, swapFacility_) {}

// Override to preserve legacy JMI storage slot
function _getMultiMintStorage() internal pure override returns (MultiMintStorage storage $) {
    bytes32 location = 0x4717d46f2e033163981fa31651301a35281b6b08316965d315fd1577bad94b00;
    assembly { $.slot := location }
}

// Override to preserve legacy MYieldToOne storage slot
function _getYieldToOneStorage() internal pure override returns (YieldToOneStorage storage $) {
    bytes32 location = 0xee2f6fc7e2e5879b17985791e0d12536cba689bda43c77b8911497248f4af100;
    assembly { $.slot := location }
}
```

**Additional USDat-level work:**
- Whitelist hooks `_beforeWrap` / `_beforeUnwrap` are already overriding the right signatures — keep them as-is
- `ForcedTransferable` is already a component pattern in PYUSDX — compatible
- Grant `versionManager` role in `initialize` (new role in PYUSDX's YieldToOne)
- Add `migrate()` function (see Section 4)
- Update `IUSDat.sol` to extend `IMultiMint` instead of `IJMIExtension`

**Behavioral differences (inherited from PYUSDX):**
- `_freeze()` silently returns if already frozen (M reverts with `AccountFrozen`)
- `_unfreeze()` silently returns if not frozen (M reverts with `AccountNotFrozen`)
- PYUSDX `Extension` includes pause + freeze checks in `_beforeWrap`/`_beforeUnwrap`/`_beforeTransfer` — USDat's Whitelist hooks call `super.*` which will apply these automatically

**Pros:** Clean code, no dead M methods, native PYUSDX semantics, yield/claim inherited  
**Cons:** Requires two-line PR to PYUSDX repo; permanent storage-slot deviation from PYUSDX standard; Freezable behavioral change

---

### Approach B — Keep JMIExtension, override in USDat (simplest, no external deps)

Keep the existing inheritance chain unchanged. Pass the PYUSDX address as the `mToken_` constructor arg and PYUSDX SwapFacility as `swapFacility_`. Override M-specific methods in `USDat.sol`.

**Constructor change:**
```solidity
// Old: constructor(address mToken_, address swapFacility_)
// New: same signature, but deployed with pyusdx and pyusdxSwapFacility args
//      `mToken` immutable now points to PYUSDX (misleading name, functional)
```

**Overrides required in USDat.sol:**

| Method | Action | Notes |
|---|---|---|
| `isAllowedAsset(address)` | Override: remove M-as-primary | `(asset == mToken) \|\| cap != 0` → just `cap != 0` |
| `isAllowedToWrap(address, uint256)` | Override: remove unlimited-M path | Remove `if (asset == mToken) return true` branch |
| `yield()` | Override: add `accruedYieldToSelfOf` | PYUSDX yield is non-rebasing |
| `claimYield()` | Override: call `claimFor(this)` first | Realize pending PYUSDX yield before minting |
| `enableEarning()` | Override: `revert` | PYUSDX earner manager handles this |
| `disableEarning()` | Override: `revert` | Same |
| `currentIndex()` | Override: return PYUSDX index | Call `IPYUSDX(mToken).currentIndex()` |
| `isEarningEnabled()` | Override: query PYUSDX | `IPYUSDX(mToken).isEarning(address(this))` or `true` |
| `wrap(address, uint256)` | Keep — now wraps PYUSDX | Same selector; PYUSDX SwapFacility uses same sig |
| `unwrap(address, uint256)` | Override: `revert`; add `unwrap(uint256)` | PYUSDX SwapFacility uses new sig without recipient |
| `replaceAssetWithM` | Override: `revert` | Replaced by `replaceAsset` |

**New functions to add:**

| Method | Signature | Notes |
|---|---|---|
| `unwrap(uint256)` | `external onlySwapFacility` | PYUSDX SwapFacility selector |
| `replaceAsset(address, address, uint256)` | `external onlySwapFacility` | With caller whitelist |
| `pyusdx()` | `external view returns (address)` | Alias for `mToken` |
| `migrate(address, address)` | `external` | One-shot M→PYUSDX reserve swap |

Note: `_revertIfInvalidAsset` in JMIExtension already reverts if `asset == mToken`. Since `mToken` now = PYUSDX, this correctly blocks PYUSDX from being used as an alt-asset — **no change needed**.

**yield() override:**
```solidity
function yield() public view override returns (uint256) {
    uint256 balance_ = _mBalanceOf(address(this)); // PYUSDX.balanceOf(this) via mToken cast
    uint256 accrued_ = IPYUSDX(mToken).accruedYieldToSelfOf(address(this));
    uint256 mBacking_ = _mBacking(); // totalSupply - totalAssets (unchanged formula)
    unchecked {
        uint256 total_ = balance_ + accrued_;
        return total_ > mBacking_ ? total_ - mBacking_ : 0;
    }
}
```

**claimYield() override:**
```solidity
function claimYield() public override returns (uint256) {
    _beforeClaimYield();
    IPYUSDX(mToken).claimFor(address(this)); // realize pending yield
    uint256 yield_ = yield();
    if (yield_ == 0) return 0;
    emit YieldClaimed(yield_);
    _mint(yieldRecipient(), yield_);
    return yield_;
}
```

**replaceAsset with whitelist:**
```solidity
// Internal whitelist storage (new ERC-7201 slot)
// setReplaceAssetWhitelistCaller(...) for ASSET_CAP_MANAGER_ROLE
// _replaceAsset calls _isCallerAllowedToReplaceAsset before proceeding
```

**Pros:** No external dependencies, zero storage risk, all existing behavior preserved  
**Cons:** ~13 overrides, misleading `mToken` name throughout, dead M methods in ABI

---

## 4. Recommendation

| | A: Inherit MultiMint | B: Keep JMIExtension |
|---|---|---|
| External dependency | PYUSDX must expose virtual accessors | None |
| Storage risk | Very low (struct verified compatible) | **Zero** |
| Code quality | Clean, no dead M code | ~13 overrides, misleading names |
| Complexity | Low after PYUSDX PR | Medium (many overrides) |
| Behavioral risk | Freezable no-op vs revert | **None** |

**Preferred: Approach A** — The two required PYUSDX changes are trivial one-liners. The struct layouts are verified compatible. It produces the cleanest USDat and avoids the misleading `mToken` naming permanently. The Freezable behavioral change (silent no-op vs revert) is acceptable since USDat's existing compliance tooling uses `ForcedTransferable` checks, not duplicate-freeze detection.

**Fallback: Approach B** — If the PYUSDX PR timeline is a blocker. Mechanically straightforward, highest confidence on storage correctness.

---

## 5. Migration Sequence (both approaches)

### Pre-migration
1. Call `claimYield()` on current USDat — realize all pending M yield
2. Pause USDat (`pause()`)
3. Treasury acquires PYUSDX: amount = `M.balanceOf(USDat_proxy)` (1:1 value assumed)
4. `PYUSDX.approve(USDat_proxy, amount)` from treasury

### 5.1 Storage validation test (required CI gate)
Run on a mainnet fork before any upgrade:
```solidity
// Verify all slot values via vm.load() before and after upgrade
// Confirm: totalSupply, yieldRecipient, all holder balances, asset caps, asset balances unchanged
// Use OZ Upgrades storage layout diff tool as a second check
```

### Atomic upgrade (`ProxyAdmin.upgradeAndCall`)
1. Deploy new implementation with `(pyusdxAddress, pyusdxSwapFacilityAddress)`
2. `upgradeAndCall` calls `migrate(treasury, oldMTokenAddress)`:
   ```solidity
   function migrate(address treasury, address oldMToken) external onlyRole(DEFAULT_ADMIN_ROLE) {
       if (_migrated) revert AlreadyMigrated();
       _migrated = true;
       uint256 amount = totalSupply(); // 1:1 PYUSDX required
       IPYUSDX(mToken).transferFrom(treasury, address(this), amount); // pull PYUSDX
       IMTokenLike(oldMToken).transfer(treasury, IMTokenLike(oldMToken).balanceOf(address(this))); // push M out
       require(IPYUSDX(mToken).balanceOf(address(this)) >= totalSupply());
   }
   ```

### Post-migration
1. Register USDat in PYUSDX's `ExtensionFactory` (if required for SwapFacility interop)
2. PYUSDX earner manager configures USDat as an earner
3. Unpause USDat
4. Configure new PYUSDX SwapFacility as the authorized swap endpoint

---

## 6. Files to Change

### Approach A
- `src/USDat.sol` — switch inheritance, 2 storage overrides, keep whitelist hooks, add `migrate()`, grant `versionManager` role
- `src/IUSDat.sol` — extend `IMultiMint`, add `migrate()`, remove `IJMIExtension` methods
- PYUSDX repo: `MultiMintStorageLayout._getMultiMintStorage()` → `virtual`; `YieldToOneStorageLayout._getYieldToOneStorage()` → `virtual`
- Add PYUSDX `evm-m-extensions` submodule (or copy relevant interfaces)

### Approach B
- `src/USDat.sol` — ~13 overrides + `replaceAsset` + `unwrap(uint256)` + `pyusdx()` + `migrate()`
- `src/IUSDat.sol` — add new signatures
- Add `IPYUSDX` interface (for `claimFor`, `accruedYieldToSelfOf`, `currentIndex`)


---

## 7. Open Questions

1. Is a PR to PYUSDX feasible for Approach A, and on what timeline?
2. Is the Freezable behavioral change (silent vs revert on duplicate freeze) acceptable?
3. Does the PYUSDX earner manager need to pre-approve USDat before migration?
4. Must the asset balance in JMI storage be drained to zero before migration, or can existing alt-asset balances carry over? (They carry over cleanly in all approaches — PYUSDX backing is `totalSupply - totalAssets`, same formula.)
5. Is the `replaceAsset` caller whitelist required at launch, or can it be added post-migration?
6. What PYUSDX SwapFacility address is used on each deployed chain?
