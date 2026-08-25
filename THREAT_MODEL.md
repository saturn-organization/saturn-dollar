# THREAT_MODEL.md

> Updated for `31e1d84` (timelock-routed upgrade + `claimMYield`) and `ec02164` (relaxed M backing check).
> Branch: `proto-963-migrate-usdat-code-to-pyusdx`.

## Scope Summary
This repo implements `USDat`, an upgradeable token migrating from a legacy M-backed `JMIExtension` model to a PYUSDX-backed `MultiMint` model. The hunt should focus on **unprivileged exploitation paths** in the repo’s own logic and integration behavior, especially around:

- the one-shot migration path: `ProposeUSDatUpgrade` -> 5-day timelock delay -> `ExecuteUSDatUpgrade` -> `ProxyAdmin.upgradeAndCall(migrate())` -> optional `replaceAsset` whitelist setup
- the **permissionless** `claimMYield()` surplus-realization path and the `balance` / `cap` / `totalAssets` invariants it moves
- reserve/accounting transitions involving `totalSupply`, `totalAssets`, M reserves (still earning), PYUSDX backing, and alt-asset registration
- authority boundaries on whitelist, freeze, forced transfer, pausing, asset-cap management, and yield handling
- wrap / unwrap / replace-asset flows reachable through the swap facility once the extension is approved

This threat model is optimized for a **critical-prioritizing automated Apex agent system**. Low-signal or low-impact bugs should be aggressively ignored.

## What Changed Since The Last Revision
These are the deltas that move the attack surface. Agents should weight them heavily.

| Change | Commit | Surface effect |
|---|---|---|
| ProxyAdmin owner is now `SaturnTimelock` (`0xfD5782E3BFF366601da3973aE30C583dE4F08A67`), 5-day `minDelay` | `31e1d84` | Upgrade payload is **public and inert for 5 days** before it executes. State can drift arbitrarily between `schedule` and `execute`. |
| `EXECUTOR_ROLE` held by `address(0)` | `31e1d84` | **Any unprivileged EOA** can execute a matured upgrade operation, and therefore choose the exact block/state in which `migrate()` runs. |
| `migrate(address mToken)` -> `migrate()`, `M_TOKEN` hardcoded constant | `31e1d84` | Removes the arbitrary-token injection surface entirely. Deprioritize it. |
| `migrate` no longer calls `stopEarning()` | `31e1d84` | M keeps earning post-migration, so real `balanceOf(M)` continuously diverges above the tracked `assets[M].balance`. Divergence is now permanent, not a one-off. |
| `migrate` check relaxed `mBalance != backing` -> `mBalance < backing`; surplus minted to `yieldRecipient` | `ec02164` | Migration no longer reverts on excess M. Excess M — including **attacker donations** — is minted 1:1 as USDat to `yieldRecipient` and registered as backing. |
| New permissionless `claimMYield()` / `mYield()` | `31e1d84` | Anyone can, at any time, move M surplus into tracked backing and mint the matching USDat to `yieldRecipient`. Raises `balance` and `totalAssets`; leaves `cap` untouched. |
| Upgrade scripts split into `ProposeUSDatUpgrade` / `ExecuteUSDatUpgrade`; `claimYield()` pre-call dropped | `31e1d84` | Off-chain ops surface. Mostly out of scope except where it changes on-chain sequencing assumptions (it does — see below). |

## Prioritized Impacts
| Impact | Priority | What it means here |
|---|---:|---|
| Unprivileged unauthorized asset or value movement | 100% | Any attacker-controlled path that drains M, PYUSDX, USDC, or USDat-backed value; converts reserves into attacker-controlled assets; or bypasses intended value custody boundaries |
| Unbacked minting / accounting corruption | 98% | Any bug that lets an unprivileged actor mint unbacked USDat, corrupt `totalAssets` / `assets[M].balance` / reserve accounting, create meaningful undercollateralization, or enable future over-redemption/dilution |
| Migration/integration exploit enabling reserve capture | 95% | Bugs in `migrate`, timelock schedule/execute sequencing, extension registration gating, or `replaceAsset` integration that let an unprivileged caller seize or redirect value during or after migration |
| Unprivileged gain of protected authority | 90% | Any bug that lets an attacker obtain or simulate privileged behavior reserved for admin/compliance/processor-like roles. **Note:** executing a matured timelock operation is by design open to all and is not itself an escalation. |
| `claimMYield` / M-surplus accounting abuse | 88% | Any way the permissionless surplus path can be driven to over-mint, double-count surplus, desync `balance` from real `balanceOf`, or be combined with `replaceAsset` / wrap for extraction |
| Compliance / permission bypass with unauthorized transferability | 82% | Whitelist, freeze, or forced-transfer boundary bypasses that let blocked users move USDat; default **high**, upgraded to **critical** if paired with value extraction |
| Durable reserve corruption without immediate same-tx payout | 80% | Meaningful accounting skew that may not cash out immediately but predictably enables later loss, dilution, or over-redemption |
| Redemption blockage / backing stranding without attacker profit | 45% | Unwrap or reserve availability failures during M -> PYUSDX transition; important, but default **medium** unless tied to unauthorized value movement |
| Event-only / UX-only / gas-only issues | 5% | Real bugs, but low priority and generally out of scope for this hunt |

## What “Critical” Means For This Repo
A finding is **critical** when an **unprivileged** attacker can do one or more of the following:

- move or extract reserve value they should not control
- mint USDat without sufficient backing
- corrupt source-of-truth accounting so the system becomes materially undercollateralized or later over-redeemable
- turn migration mechanics — including the 5-day timelock window and the open executor — into an attacker-controlled value-conversion path
- obtain protected authority or bypass a core authority boundary in a way that directly enables unauthorized value movement

A representative high-value finding for this hunt is:

- **"Unprivileged caller can convert M reserves into attacker-controlled assets during migration"**

## Severity Bar
### Critical
- Unprivileged unauthorized movement or extraction of M, PYUSDX, USDC, or equivalent backing value
- Unbacked USDat minting, including via `migrate`'s surplus mint or `claimMYield`
- Material accounting corruption causing meaningful undercollateralization, dilution, or future over-redemption
- Migration or integration bug that lets an attacker capture reserves or redirect settlement flows, including by choosing the state in which the matured timelock operation executes
- Unprivileged acquisition of privileged capability when it directly enables the outcomes above

### High
- Compliance boundary bypass (`whitelist`, `freeze`, forced-transfer constraints) that allows unauthorized transfers or policy evasion, but does not itself create unbacked minting or reserve theft
- Serious integration/state-machine bugs that create a strong, realistic path to loss but stop short of direct extraction
- Nontrivial reserve/accounting skew with meaningful security impact, but weaker or more conditional monetization

### Medium
- Unwrap/redemption blockage or stranded backing during migration without attacker-controlled value movement
- Griefing of `claimMYield` or `migrate` that costs the attacker real M and yields them nothing
- Security-relevant integration mistakes that break functionality or safety assumptions but do not create direct theft, unbacked minting, or strong future extraction

### Low
- Event-only discrepancies
- Low-impact whitelist UX issues
- Temporary pauses as an operational nuisance
- Gas-only griefing
- Admin-only misconfiguration issues that do not let an unprivileged actor escalate or steal
- Uninitialized-implementation observations on a TransparentUpgradeableProxy (see Known Issues)

## Attacker Capabilities
### Realistic / In Scope
- Any unprivileged EOA or contract interacting through normal on-chain entrypoints
- **Reading the scheduled timelock payload and acting during the 5-day delay**, including donating tokens, moving supply, or manipulating reserve balances so `migrate()` executes against attacker-shaped state
- **Calling `TimelockController.execute` themselves** once the delay matures, choosing the exact block and surrounding transactions
- Front-running, back-running, and timing around public transaction sequences
- Direct token donations to the USDat proxy (M, PYUSDX, or other assets) to perturb balance-vs-tracked accounting
- Calling repo-exposed or integration-reachable flows in ordinary ways, including `claimMYield` and wrap/unwrap/replace-asset paths when enabled by the system state
- Exploiting repo logic mistakes in state transitions, accounting, access checks, or integration assumptions while dependencies behave honestly
- Chaining multiple repo bugs together if the combined path remains realistically attacker-executable

### Explicitly Out of Scope
- Malicious or compromised trusted role holders (`SaturnTimelock` proposer/canceller `0x610182581C93687Ca03F4a8E7f124f8cEC616820`, compliance, processor, factory manager, earner manager, etc.) **unless** the repo contains a bug that lets an unprivileged actor gain or simulate that power
- Assuming `PYUSDX`, the M token, `TimelockController`, swap facilities, or `ExtensionFactory` are themselves malicious or broken; treat dependencies as trusted/honest by default
- Purely operational or governance failures outside the repo’s enforceable logic
- The fact that `EXECUTOR_ROLE == address(0)` by itself — this is a deliberate configuration. Only report it when paired with a concrete state-manipulation path that makes open execution exploitable.

## Highest-Value Attack Surfaces
- **The 5-day timelock window:** the exact `upgradeAndCall(migrate())` payload is public and inert for five days. What can an unprivileged actor change about USDat's state in that window such that `migrate()` registers wrong backing, mints excess USDat, or leaves exploitable state? `ProposeUSDatUpgrade` dry-runs the payload at *schedule* time, not at *execute* time — that gap is the interesting part.
- **`migrate()` surplus mint:** `surplus = mBalance - backing` is minted 1:1 to `yieldRecipient` and the whole `mBalance` is registered with `cap == balance == mBalance`. Probe whether donated or attacker-timed M can skew `totalAssets`, `cap`, or the PYUSDX-backed portion (`totalSupply - totalAssets`).
- **`claimMYield()` (permissionless):** it raises `assets[M].balance` and `totalAssets` and mints to `yieldRecipient` in the same step. Probe for double-counting against `replaceAsset`, ordering effects with wrap/unwrap, `safe240` boundary behavior on `balance`, and whether any path lets `balance` exceed real `balanceOf(M)`.
- **`balance` vs `cap` divergence on M:** `migrate` sets `cap == balance`; `claimMYield` raises only `balance`; `replaceAsset` lowers only `balance`. Every path that moves one without the other is worth tracing (see Known Issues for the one already identified).
- **Reserve/accounting invariants:** consistency between held balances and logical accounting (`totalSupply`, `totalAssets`, alt-asset balances/caps, PYUSDX backing), given M is **still earning** and thus continuously divergent.
- **`replaceAsset` flow:** whether reserve replacement can be abused to drain M, mis-credit backing, or convert assets to attacker benefit
- **Wrap/unwrap gating:** whether whitelist checks, pause/freeze constraints, or extension-approval assumptions can be bypassed to move value or violate policy
- **Authorization boundaries:** role-protected actions around asset caps, replace-asset allowlisting, yield claiming, pause/freeze, and forced transfers
- **State-machine edges during migration:** one-shot `reinitializer(2)` behavior, post-upgrade approval gating, and conditions where unwrap becomes possible

## Known Issues — Already Identified, Do Not Re-Report As Novel
These are documented in `31e1d84`'s commit message and deliberately not addressed. Report them **only** if you find a materially stronger or different exploitation path than described here.

1. **`replaceAsset` reopens M wrap room.** `cap == balance` holds only at migration. `replaceAsset` lowers `balance` while `cap` stays put, so each drain of `D` opens exactly `D` of M wrap headroom. M can be wrapped back in, undoing the drain and round-tripping to PYUSDX at the treasury's expense. Zeroing `cap` is not the fix — `replaceAsset` and `claimMYield` both gate on `isAllowedAsset` (`cap != 0`), so it would halt the drain it is meant to protect. **Contained today only by the whitelist being enabled.** Tracked separately.
   - *Still valuable:* any path that reaches this without being whitelisted, or that amplifies it beyond a `D`-for-`D` round trip.
2. **M donations are absorbed, not rejected.** Both `migrate` and `claimMYield` treat any excess `balanceOf(M)` as claimable yield and mint it to `yieldRecipient`. A donor pays real M and the proceeds reach only `yieldRecipient`, so this is understood as unprofitable griefing.
   - *Still valuable:* any variant where the donor, not `yieldRecipient`, captures value, or where the donation breaks a cap/backing invariant rather than just shifting it.
3. **`claimMYield` is intentionally permissionless.** Proceeds can only ever reach `yieldRecipient`, so no role gate was added. The `_revertIfFrozen(yieldRecipient)` guard is retained deliberately for incident response.
   - *Still valuable:* any path where a caller influences *where* the mint lands, or where forced ordering of `claimMYield` against another operation causes loss.

## Assumptions & Constraints
- Static-analysis threat model only; no claims here depend on live chain queries or runtime testing
- Repo logic and documented integration behavior are in scope; external dependencies are assumed honest unless repo logic misuses them
- The meaningful attacker is **unprivileged** by default, and now explicitly includes the party that broadcasts `execute` on the matured timelock operation
- Migration-sequence and steady-state issues are equally important for this hunt
- Pure availability issues without theft or meaningful accounting damage are not default top priority
- Apex agents should prefer exploit paths that are concrete, realistic, and monetizable or that clearly create material undercollateralization / future over-redemption

## Out-of-Scope
### Ignore Aggressively
- Low-impact whitelist UX problems
- Admin-only misconfigurations
- Event-only discrepancies
- Temporary pauses without deeper exploitability
- Gas-only griefing
- Off-chain ergonomics of the propose/execute scripts (env-var handling, console output, `NEW_IMPLEMENTATION` mismatch producing an unknown operation id — the `isOperationReady` require already names it)
- Arbitrary-`mToken` injection into `migrate` — the parameter no longer exists

### Why These Are Out
- They do not match the user’s preferred critical target set
- They do not represent unprivileged unauthorized value movement, unbacked minting, or material accounting corruption
- They consume Apex agent bandwidth while the system is explicitly optimized for critical outcomes

### Also Out Unless Escalated By Another Bug
- Findings that require a trusted role holder to be malicious or compromised
- Findings that require the timelock proposer/canceller to be malicious
- Dependency bugs where the repo is not the exploitable root cause
- Pure migration inconvenience or redemption delay with no realistic loss path beyond the already-accepted medium-severity category
- The implementation contract being reachable directly (no `_disableInitializers`): it sits behind a TransparentUpgradeableProxy with no beacon, `pinVersion`/`unpinVersion` are hard-disabled, and a `migrate()` call on the bare implementation operates on empty storage. Report only with a concrete impact on the proxy's state or value.

## Production / Default Configuration
The following reflects **static verification attempts** from the repo docs and code review of `README.md`, `plans/`, `src/USDat.sol`, `src/interfaces/IUSDat.sol`, `script/PYUSDx_Deployment/UpgradeUSDatBase.sol`, `script/PYUSDx_Deployment/ProposeUSDatUpgrade.s.sol`, `script/PYUSDx_Deployment/ExecuteUSDatUpgrade.s.sol`, and the test suite. No live-chain verification was performed here.

### Enabled
- **Transparent upgradeable proxy architecture:** documented in repo README and migration notes
- **Timelock-gated upgrade:** ProxyAdmin owned by `SaturnTimelock` since block 25,284,032; 5-day `minDelay`; `PROPOSER_ROLE` and `CANCELLER_ROLE` at `0x610182581C93687Ca03F4a8E7f124f8cEC616820`; `EXECUTOR_ROLE` at `address(0)` (open execution). The same handover moved the token's `DEFAULT_ADMIN_ROLE` to the timelock.
- **One-shot migration via `upgradeAndCall`:** `migrate()` is the intended upgrade-time reinitializer (`reinitializer(2)`), invoked as the `data` of `ProxyAdmin.upgradeAndCall`
- **M earning left ON through and after migration:** `migrate` deliberately does not call `stopEarning`, so M yield accrues across the entire `replaceAsset` drain window
- **Permissionless `claimMYield()`:** realizes untracked M surplus into backing and mints the match to `yieldRecipient`; gated only on `isAllowedAsset(M_TOKEN)` and `_revertIfFrozen(yieldRecipient)`
- **M reserve carry-over as a replaceable alt-asset after migration:** implemented in `migrate`
- **Extension approval as the post-upgrade gate for swap facility paths:** documented in migration notes; until registration, wrap/unwrap/replaceAsset are expected to revert
- **Role-based controls for compliance and operations:** present in code/tests for whitelist, freeze, pause, forced transfer, yield-recipient management, and asset-cap management

### Disabled
- **Public fresh initialization path on the new implementation:** the upgrade implementation exposes `migrate`, not a normal fresh `initialize` flow for production deployment
- **Version pinning:** `pinVersion` / `unpinVersion` are hard-disabled and revert by design
- **Immediate post-migration M re-wrapping headroom:** migration sets `cap == balance` for M, and `claimMYield` pushes `balance` above `cap`, so new M wrapping is blocked until `replaceAsset` lowers `balance` again
- **Immediate unwrap capacity backed by PYUSDX right after migration:** documented as unavailable until `replaceAsset` builds PYUSDX reserves
- **Pre-upgrade `claimYield()` call:** removed from the upgrade script; `migrate`'s own surplus mint absorbs yield accrued across the timelock delay

### Unknown
- **Whether the live whitelist is currently enabled:** code supports both states. This is now a **security-critical** unknown, not a compliance detail — the known `replaceAsset`/`cap` re-wrap issue is contained *only* by the whitelist being on.
- **Whether `replaceAsset` is permissionless or allowlisted in the live environment:** migration notes say allowlisting is optional and must be configured separately
- **Whether earner registration and extension registration are already live at the exact current deployment state:** documented as prerequisites / steps, but not independently verified here
- **Whether an upgrade operation is currently scheduled on the timelock, and at what maturity:** not verified on-chain here
- **Exact live role assignments at the present block:** the migration doc lists holders at a fork block, but this threat model does not verify current on-chain assignments

## Apex agent Guidance
- Start with **value-moving state transitions** and **reserve/accounting invariants**, not UI or event-level mismatches
- Give the **5-day timelock window** first-class attention: the payload is committed and public, but the state it lands on is not
- Trace every path that moves `assets[M].balance`, `assets[M].cap`, `totalAssets`, and `totalSupply` independently of one another
- Treat migration and steady-state bugs as equally important
- Prefer findings with a concrete attacker path from ordinary unprivileged interaction
- Do not spend time on privileged-malice scenarios unless the repo lets an unprivileged actor obtain that power
- Check the Known Issues section before writing up an M-donation or `replaceAsset`-cap finding; only report a materially stronger path
- Assume dependencies are honest; focus on exploitable misuse or unsafe integration from this repo

## Ideal Finding Shapes
The best reports for this hunt usually look like one of these:

- unprivileged reserve extraction through wrap/unwrap/replace-asset edge cases
- state manipulation during the timelock delay that makes `migrate()` register wrong backing or over-mint on execution
- `claimMYield` accounting abuse: double-counted surplus, `balance` exceeding real `balanceOf`, or ordering effects against `replaceAsset`
- migration-time reserve misregistration or accounting skew that creates attacker-capturable value
- unbacked USDat minting or future over-redemption through invariant breakage
- compliance or authorization bypass that directly enables forbidden value movement

Anything substantially below that bar should be deprioritized.
