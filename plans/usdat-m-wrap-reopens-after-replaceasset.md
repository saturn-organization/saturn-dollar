# M wraps re-open as the M reserves are drained

**Status:** open — documented, not fixed. No code change has been made for this.
**Component:** `src/USDat.sol` (`migrate`), inherited `MultiMint._wrapAsset` / `_replaceAsset`
**Pre-existing:** yes. Present since `migrate` first registered M as a replaceable asset; not introduced by the keep-M-earning / `claimMYield` change.

## Summary

`migrate` registers M with `cap == balance`, which blocks M wraps *at that instant only*. Every `replaceAsset` lowers `balance` but leaves `cap` untouched, opening exactly as much wrap room as was drained. Once room exists, M can be wrapped back into USDat — undoing migration progress, and doing so profitably as a round-trip that consumes the treasury's PYUSDX.

The whitelist (currently enabled on mainnet) is what keeps this from being open to the public today. It is a live footgun rather than a public exploit.

## Mechanism

`MultiMint.isAllowedToWrap` is, in essence:

```solidity
return assetCap(asset) >= (assetBalanceOf(asset) + effectiveAmount);
```

Let `B` be the M balance at migration.

| Step | `cap` | `balance` | wrap room (`cap - balance`) |
| --- | --- | --- | --- |
| after `migrate` | `B` | `B` | `0` — blocked |
| after `replaceAsset(D)` | `B` | `B − D` | **`D` — open** |
| after `claimMYield(S)` | `B` | `B − D + S` | `D − S` |

`migrate` sets `cap` and `balance` to the same value, so the block is incidental to them being equal — not an invariant anything maintains. `_replaceAsset` decrements only `balance`. Nothing lowers `cap`.

`claimMYield` narrows the window (it raises `balance` by the realized surplus) but that is incidental and does not close it.

### Reachability

The SwapFacility's only gate on the alt-asset wrap path is `_revertIfCannotMultiMint`, which checks `isAllowedAsset(asset)` — i.e. `cap != 0`. M passes that for the entire drain period. So `SwapFacility.swap(tokenIn: M, tokenOut: USDat, …)` routes to `_swapInMultiMint` → `USDat.wrap(M, recipient, amount)` → `MultiMint._wrapAsset`.

The remaining gate is USDat's own `_beforeWrap(asset, account, recipient, amount)` override, which enforces the whitelist on both depositor and recipient.

## Why it round-trips (the part that makes it more than cosmetic)

Wrapping M in does not merely restore M backing — it is immediately reversible for PYUSDX. Tracking `_pyusdxBacking()` (`totalSupply − totalAssets`), starting from a fully M-backed state (`totalSupply == totalAssets == B`):

1. **After `replaceAsset(D)`** — `totalAssets = B − D`, `totalSupply` unchanged (`replaceAsset` does not mint). Backing `= D`. The contract now holds `D` PYUSDX, which the treasury paid in.
2. **Attacker wraps `D` of M** — `totalSupply += D` and `totalAssets += D`, so backing is **still `D`**. They now hold `D` USDat.
3. **Attacker unwraps `D` USDat** — permitted, since `_beforeUnwrap` only requires `backing >= amount`. They receive `D` PYUSDX.

Net: the treasury spent `D` PYUSDX to remove `D` M; the attacker converted `D` M into that same `D` PYUSDX at par. The reserves are back to `B` M and backing is back to `0`. **Migration progress can be undone as fast as it is made**, and the drain never completes.

The economic loss depends on M's value. If M redeems at par the loss is ~nil and this is griefing — the migration simply cannot finish. If M is impaired or being wound down (a plausible reason to be migrating at all), the delta is a direct loss.

## Reproduction

Verified against the unit suite. Bob holds no roles; `deployCodeTo` places the mock at `USDat.M_TOKEN`. Observed output:

```
cap   after migrate: 1000000000
bal   after migrate: 1000000000
cap   after drain:   1000000000
bal   after drain:    600000000
bob USDat minted from M: 400000000
```

```solidity
function test_PROBE_wrapMAfterDrain() public {
    _setUpForMigration(AMOUNT);
    usdat.migrate();

    // Right after migrate: cap == balance, no room.
    assertFalse(usdat.isAllowedToWrap(address(mToken), 1));

    // Drain 400e6 of M out for PYUSDX.
    vm.prank(processor);
    usdat.setReplaceAssetWhitelistCaller(treasury, true);
    uint256 drain = 400e6;
    _mintPyusdx(treasury, drain);
    vm.startPrank(treasury);
    pyusdx.approve(address(swapFacility), drain);
    swapFacility.replaceAsset(address(usdat), address(mToken), drain, treasury);
    vm.stopPrank();

    // Room has opened up, exactly equal to the drained amount.
    assertTrue(usdat.isAllowedToWrap(address(mToken), drain), "M wrap re-opened");

    // And bob, an arbitrary user, can actually push M back in.
    mToken.mint(bob, drain);
    vm.startPrank(bob);
    mToken.approve(address(swapFacility), drain);
    swapFacility.swapInAsset(address(usdat), address(mToken), drain, bob);
    vm.stopPrank();

    assertEq(usdat.balanceOf(bob), drain);
    assertEq(usdat.assetBalanceOf(address(mToken)), AMOUNT); // reserves restored — migration undone
}
```

Note this probe uses `MockSwapFacility.swapInAsset`. The production path is `SwapFacility.swap(tokenIn, tokenOut, …)` → `_swapInMultiMint`; the extension-side gating exercised is identical.

## What contains it today

**The whitelist is enabled on mainnet.** Verified at fork block 25,284,032:

```
$ cast call 0x23238f20b894f29041f48D88eE91131C395Aaa71 "isWhitelistEnabled()(bool)"
true
```

`USDat._beforeWrap` checks `_revertIfNotWhitelisted` on both the depositor and the recipient, so the wrap-back is currently limited to whitelisted addresses. That means:

- It is **not** open to the public as things stand.
- It **becomes** open the moment `disableWhitelist()` is called — which is otherwise an unrelated, reasonable-looking operational decision with no signposted connection to M.
- Any currently whitelisted party can already do it.

The whitelist storage lives at the `Saturn.storage.Whitelist` ERC-7201 slot and carries across the upgrade, so this holds post-migration.

## Why the obvious fix does not work

**Setting `cap = 0` halts the drain.** `_replaceAsset` begins with `if (!isAllowedAsset(asset)) revert AssetNotAllowed(asset)`, and `isAllowedAsset` is `cap != 0`. Zeroing the cap to block wraps also blocks the very `replaceAsset` calls the migration depends on (and `claimMYield`, which carries the same guard). The cap must stay non-zero for the entire drain, which is precisely the period the window is open.

## Options

1. **Override `_beforeWrap(asset, …)` in `USDat` to reject `M_TOKEN` outright.** Makes M structurally one-way — out via `replaceAsset`, never in. Closes the window permanently with no ongoing discipline and no dependence on the whitelist. Costs a contract change and re-review of the upgrade.
2. **Ratchet the cap down after every drain** (`setAssetCap(M_TOKEN, newBalance)`, `ASSET_CAP_MANAGER_ROLE`). No contract change, but converts a structural guarantee into a standing operational obligation: the window is open between each `replaceAsset` and its follow-up `setAssetCap`, and forgetting once (or a partial fill) leaves it open. Interacts awkwardly with `claimMYield`, which raises `balance` above a freshly-ratcheted `cap`.
3. **Accept and document**, relying on the whitelist. Requires that "never disable the whitelist while M is registered" become an explicit, enforced constraint in the runbook — currently it is not written down anywhere.

**Recommendation:** option 1. It is the only one that does not depend on ongoing human discipline, and it matches the stated intent that M is drained and never re-accepted.

## Follow-ups if this is left open

- Record in `usdat-pyusdx-migration-runbook.md` that the whitelist must not be disabled while M's cap is non-zero.
- The comments in `USDat.claimMYield` ("`cap` is left alone … keeps M wraps blocked") and the `assertFalse(usdat.isAllowedToWrap(...))` assertions in `test/USDat.t.sol` and `test/UpgradeUSDatFork.t.sol` are only valid pre-drain. They read as general guarantees and should be corrected or scoped, since they currently assert the property in exactly the state where it holds.
