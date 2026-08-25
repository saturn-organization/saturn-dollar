# Keep M earning through the migration + add `claimMYield`

## Context

USDat is being upgraded from the M-backed JMIExtension to the PYUSDX `MultiMint` implementation via `ProxyAdmin.upgradeAndCall` → `migrate(mToken)` (`src/USDat.sol:70`). Today `migrate` calls `IMTokenLike(mToken).stopEarning()`, permanently opting the contract out of M earning at upgrade time.

The held M will be drained into PYUSDX progressively via `replaceAsset`, which can take a while. Stopping earning at upgrade forfeits all M yield accrued during that window. So we want to **keep earning**: remove the `stopEarning()` call.

But once M is registered as a replaceable alt-asset, `MultiMint` accounting only sees the snapshot in `$.assets[mToken].balance` — M yield accrues invisibly on the contract's actual `balanceOf` and is not claimable by anything: `claimYield()` only realizes PYUSDX excess, and `replaceAsset` only moves the tracked balance. Hence we also need a function, callable any time post-migration, that realizes the surplus (`actual M balance − tracked balance`) to the yield recipient — exactly like the surplus block already in `migrate` (`src/USDat.sol:80-96`).

**Decisions (confirmed with user):**
- **M-only `claimMYield()`** — no generic multi-asset support (avoids decimal-conversion complexity; M shares the extension's 6 decimals so surplus maps 1:1). To make it *truly* M-only, the M address is a **hardcoded constant** in USDat (`address public constant M_TOKEN = 0x866A2BF4E572CbcF37D5071A7a58503Bfb36be1b`, same value as `script/PYUSDx_Deployment/UpgradeUSDatBase.sol:25`). USDat is upgrade-only and mainnet-only, so hardcoding is safe; constructor and deploy script constructor-data stay untouched. No function takes an asset address anymore. Bonus: the public getter restores an `mToken` view like the legacy JMIExtension ABI exposed.
- **Permissionless** — anyone can call; it always mints to `yieldRecipient()`. Unlike `claimYield()`, no `YIELD_RECIPIENT_MANAGER_ROLE` gate. Keep the frozen-yield-recipient revert (same incident-response rationale as `_beforeClaimYield`, `lib/PYUSDX/src/platform/projects/YieldToOne.sol:186`).

## Changes

### 1. `src/USDat.sol`

**New constant** (next to `WHITELIST_MANAGER_ROLE`):
```solidity
/// @inheritdoc IUSDat
address public constant M_TOKEN = 0x866A2BF4E572CbcF37D5071A7a58503Bfb36be1b;
```

**`migrate` (line 70-97):** now `migrate() external reinitializer(2)` — no param, uses the `M_TOKEN` constant.
- Delete the `stopEarning()` call and its NOTE (lines 71-72). Drop the now-unused `IMTokenLike` import.
- The rest is unchanged and stays correct: for an earning account, M's `balanceOf` already includes accrued yield (principal × index), so `mBalance`, the `MReservesMismatch` check, the surplus mint, and the asset registration all still work.

**New `claimMYield() external returns (uint256)`** (new "Yield" section next to migration):

```solidity
function claimMYield() external returns (uint256) {
    // Unreachable on the live proxy (migrate registers M atomically with the upgrade);
    // guards against realizing "surplus" before M is registered as backing.
    if (!isAllowedAsset(M_TOKEN)) revert InvalidAsset(M_TOKEN); // IMultiMint error, inherited

    // Same incident-response guard as _beforeClaimYield, minus the role gate.
    _revertIfFrozen(_getFreezableStorageLocation(), yieldRecipient());

    MultiMintStorage storage $ = _getMultiMintStorage();

    uint256 balance = IERC20(M_TOKEN).balanceOf(address(this));
    uint256 tracked = $.assets[M_TOKEN].balance;

    if (balance <= tracked) return 0;

    uint256 surplus = balance - tracked; // 1:1 — M and the extension are both 6 decimals

    // Register the surplus as backing so totalSupply − totalAssets (PYUSDX backing) is unchanged.
    $.assets[M_TOKEN].balance += UIntMath.safe240(surplus);
    $.totalAssets += surplus;

    emit YieldClaimed(surplus);
    _mint(yieldRecipient(), surplus);

    return surplus;
}
```

Design points (all reuse existing code — no new machinery beyond the constant):
- **Must** bump `$.assets[M_TOKEN].balance` and `$.totalAssets` alongside the mint, exactly as `migrate` does — minting without registering would inflate `_pyusdxBacking()` and corrupt `_excess()`/unwrap accounting.
- `cap` is left untouched: it is a governance parameter (`setAssetCap`); `balance > cap` just keeps M wraps blocked (`isAllowedToWrap` returns false), which is desired.
- `balance <= tracked → return 0` guards underflow: M earner transfers round principal up, so after `replaceAsset` the actual M balance can sit a few wei below tracked until accrual catches up. (Known accepted edge: a final `replaceAsset` of the full tracked balance can revert for wei-level dust; claiming first mitigates.)
- Emits the existing `YieldClaimed` event (as `migrate` does). Zero-surplus returns 0 with no event, matching `claimYield()`.
- No pause check, matching `claimYield()`'s reasoning: minted tokens are inert while paused.

**New view `mYield() view returns (uint256)`** — the pending claimable surplus (mirrors `yield()`), since the whole point is that this amount is otherwise untrackable on-chain. Same surplus computation; returns 0 when `balance <= tracked` or M isn't registered yet.

### 2. `src/interfaces/IUSDat.sol`
- Declare `M_TOKEN()`, `claimMYield()`, and `mYield()` with NatSpec (permissionless; mints the M surplus to the yield recipient and registers it as backing).
- Update `migrate` to zero-arg + NatSpec (lines 83-92): no longer "Stops M earning" — the contract keeps earning M; accrued yield is realized later via `claimMYield`.
- No new error: `InvalidAsset` comes from `IMultiMint`.

### 3. `src/interfaces/IMTokenLike.sol`
- Remove `stopEarning()` (no longer used anywhere in `src/`). Keep `isEarning` — the fork test uses it.

### 4. `script/PYUSDx_Deployment/UpgradeUSDatBase.sol`
- `_buildUpgradeAndCallData`: `abi.encodeCall(USDat.migrate, ())` (line 56).
- Optionally replace the local `M_TOKEN` constant with a reference to `USDat`'s (single source of truth); constructor data unchanged.

### 5. Tests (TDD — write each failing test before the code change it drives)

**`test/PYUSDx_Deployment/USDatHarness.sol`:** remove `MockMToken.stopEarning()` and its comment (compile-level proof migrate no longer calls it).

**`test/PYUSDx_Deployment/USDat.t.sol`:** since `M_TOKEN` is a hardcoded address, place the mock there in `setUp` with forge-std's `deployCodeTo` (runs the constructor at the target address, so name/symbol/decimals storage is set correctly):
```solidity
deployCodeTo("USDatHarness.sol:MockMToken", usdat.M_TOKEN());
mToken = MockMToken(usdat.M_TOKEN());
```
`_setUpForMigration` uses that stored mock instead of `new MockMToken()`. Then a new `claimMYield` section:
- `test_claimMYield_mintsSurplusToYieldRecipient` — migrate, `mToken.mint(usdat, 25e6)` to simulate accrual, call from a random unprivileged address (also proves permissionless); assert return value, `YieldClaimed` emitted, yieldRecipient balance, `totalSupply`, `assetBalanceOf`, `totalAssets` all +25e6, `assetCap` unchanged, `isAllowedToUnwrap(1)` still false.
- `test_claimMYield_zeroSurplus_returnsZero` — no mint, returns 0, no logs, no state change.
- `test_claimMYield_revertsBeforeMigration` — skip `migrate` → `IMultiMint.InvalidAsset`.
- `test_claimMYield_revertsWhenYieldRecipientFrozen` — freeze recipient → `IFreezable.AccountFrozen`.
- `test_mYield_viewMatchesClaim` — view equals surplus before claim, 0 after.
- Existing migrate tests: same behavior, call sites become `usdat.migrate()`.

**`test/PYUSDx_Deployment/UpgradeUSDatFork.t.sol`:**
- `test_upgradeAndMigrate_timelock`: flip `assertFalse(IMTokenLike(M_TOKEN).isEarning(USDAT_PROXY))` (line 156) to `assertTrue`, update the comments at lines 97 and 155; `migrate()` revert-check call site loses its arg; assert `usdat.M_TOKEN() == M_TOKEN` (constant matches the live M).
- New `test_claimMYield_realizesMYieldAccruedAfterUpgrade`: run `_doTimelockUpgrade()`, warp forward (M index keeps growing), compute `surplus = M.balanceOf(proxy) − assetBalanceOf(M_TOKEN)`, `assertGt(surplus, 0)` (proves earning continued), call `usdat.claimMYield()` from an unprivileged address, assert recipient mint + `assetBalanceOf(M_TOKEN)` now equals the actual M balance + `totalAssets` bump + cap unchanged.

### Out of scope
- M0-side earner status: continued earning requires USDat to remain an approved M earner. If governance ever disapproves it, anyone can stop its earning on the M token itself; `claimMYield` still realizes everything accrued to that point. No contract handling needed.

## Verification
1. `forge build`
2. `forge test --no-match-contract Fork` — unit suite.
3. `forge test --match-contract UpgradeUSDatForkTest` (needs `MAINNET_RPC_URL`) — full timelock upgrade flow, earning-continues assertion, and post-upgrade yield claim on real M.
