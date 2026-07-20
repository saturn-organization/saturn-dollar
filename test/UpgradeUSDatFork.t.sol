// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "openzeppelin-contracts/contracts/governance/TimelockController.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {USDat} from "../src/USDat.sol";
import {UpgradeUSDatBase, IJMIExtensionLegacy} from "../script/UpgradeUSDatBase.sol";
import {IMTokenLike} from "../src/interfaces/IMTokenLike.sol";

/// @dev Minimal surface for asserting who controls the ProxyAdmin at the fork block.
interface IOwnableLike {
    function owner() external view returns (address);
}

contract UpgradeUSDatForkTest is Test, UpgradeUSDatBase {
    address constant M_SWAP_FACILITY = 0xB6807116b3B1B321a390594e31ECD6e0076f6278;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Holds PROPOSER_ROLE and CANCELLER_ROLE on the timelock. It owned the ProxyAdmin and held the
    // token's DEFAULT_ADMIN_ROLE until block 25,284,032, when it handed both to the timelock.
    address constant PROPOSER = 0x610182581C93687Ca03F4a8E7f124f8cEC616820;

    // EXECUTOR_ROLE is held by address(0), so execution is open to anyone. Use an unrelated address to
    // prove the executor needs no privileges of its own.
    address constant EXECUTOR = address(0xA11CE);

    // Live role holders at the fork block, granted during the original JMIExtension deploy and untouched
    // by the handover to the timelock.
    address constant ROLE_MANAGER = 0x10D59F776db12b4B271b2609CB8b7Ddd0A82703B; // freeze/pause/forced-transfer/whitelist
    address constant YIELD_RECIPIENT_MANAGER = 0x09D6E34cE24D54890fF0BC6a090b5f880F8C729f;
    address constant ASSET_CAP_MANAGER = 0x7D343D17896D2cd87A49b4fB8872298A883f78f7;

    // The same proxy, viewed through its pre-upgrade (JMIExtension) and post-upgrade (USDat) interfaces.
    IJMIExtensionLegacy public legacyProxy = IJMIExtensionLegacy(USDAT_PROXY);
    USDat public usdat = USDat(USDAT_PROXY);
    TimelockController public timelock = TimelockController(payable(TIMELOCK));

    function setUp() public {
        // First block at which the timelock owns the ProxyAdmin.
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 25_284_032);
    }

    /* ============ Timelock upgrade helpers ============ */

    /// @dev Deploys the implementation and schedules the upgrade as the proposer, mirroring
    ///      `ProposeUSDatUpgrade`. Returns what `_execute` needs to rebuild the operation.
    function _schedule() internal returns (address proxyAdmin, bytes memory payload) {
        address impl = _deployImplementation();
        (proxyAdmin, payload) = _buildUpgradeAndCallData(impl);

        uint256 delay = timelock.getMinDelay();

        vm.prank(PROPOSER);
        timelock.schedule(proxyAdmin, 0, payload, PREDECESSOR, SALT, delay);
    }

    /// @dev Executes a matured operation, mirroring `ExecuteUSDatUpgrade`.
    function _execute(address proxyAdmin, bytes memory payload) internal {
        vm.prank(EXECUTOR);
        timelock.execute(proxyAdmin, 0, payload, PREDECESSOR, SALT);
    }

    /// @dev The whole flow: schedule, wait out the delay, execute.
    function _doTimelockUpgrade() internal {
        (address proxyAdmin, bytes memory payload) = _schedule();
        vm.warp(block.timestamp + 5 days + 1);
        _execute(proxyAdmin, payload);
    }

    /* ============ Pre-upgrade state checks ============ */

    function test_preUpgrade_state() external view {
        uint256 usdcBalance = 100_000001;

        assertEq(IOwnableLike(Upgrades.getAdminAddress(USDAT_PROXY)).owner(), TIMELOCK);

        assertEq(legacyProxy.mToken(), M_TOKEN);
        assertEq(legacyProxy.swapFacility(), M_SWAP_FACILITY);
        assertEq(legacyProxy.totalSupply(), 120_647_934_180848);
        assertEq(legacyProxy.totalAssets(), usdcBalance);
        assertEq(IERC20(USDC).balanceOf(USDAT_PROXY), usdcBalance);
        assertEq(legacyProxy.assetBalanceOf(USDC), usdcBalance);

        uint256 mBalance = IERC20(M_TOKEN).balanceOf(USDAT_PROXY);
        uint256 mBacking = legacyProxy.totalSupply() - legacyProxy.totalAssets() + legacyProxy.yield();

        assertEq(mBalance, mBacking);
    }

    /* ============ Full timelock upgrade + migrate flow ============ */

    function test_upgradeAndMigrate_timelock() external {
        // The proxy earns M yield pre-upgrade; migrate must leave that on so the reserves keep
        // yielding while they are drained into PYUSDX.
        assertTrue(IMTokenLike(M_TOKEN).isEarning(USDAT_PROXY));

        (address proxyAdmin, bytes memory payload) = _schedule();

        // The operation is real but embargoed until the delay matures.
        bytes32 id = timelock.hashOperation(proxyAdmin, 0, payload, PREDECESSOR, SALT);
        assertFalse(timelock.isOperationReady(id));

        vm.warp(block.timestamp + 5 days + 1);
        assertTrue(timelock.isOperationReady(id));

        // Snapshot pre-claim state.
        address yieldRecipient = legacyProxy.yieldRecipient();
        uint256 totalSupplyBefore = legacyProxy.totalSupply();
        uint256 totalAssetsBefore = legacyProxy.totalAssets();
        uint256 mBalanceBefore = IERC20(M_TOKEN).balanceOf(USDAT_PROXY);
        uint256 usdcBalanceBefore = IERC20(USDC).balanceOf(USDAT_PROXY);
        uint256 yieldRecipientBalanceBefore = legacyProxy.balanceOf(yieldRecipient);
        uint256 pendingYield = legacyProxy.yield();

        // Only USDC is an accepted alt-asset with a balance
        assertEq(usdcBalanceBefore, totalAssetsBefore);

        _execute(proxyAdmin, payload);

        // Verify migrate realized the pending yield
        uint256 totalSupplyAfter = totalSupplyBefore + pendingYield;
        uint256 mBalanceAfter = IERC20(M_TOKEN).balanceOf(USDAT_PROXY);

        assertEq(usdat.totalSupply(), totalSupplyAfter);
        assertEq(usdat.balanceOf(yieldRecipient), yieldRecipientBalanceBefore + pendingYield);

        // Verify post-migration state

        // The new implementation is wired to PYUSDX, not the legacy M swap facility, and its hardcoded
        // M constant names the M the proxy actually holds.
        assertEq(usdat.pyusdx(), PYUSDX);
        assertEq(usdat.swapFacility(), PYUSDX_SWAP_FACILITY);
        assertEq(usdat.M_TOKEN(), M_TOKEN);

        // migrate mints the surplus as extension tokens (not M), so the proxy's held M is unchanged; it
        // then registers that held M as a replaceable alt-asset with 6 decimals.
        assertEq(mBalanceAfter, mBalanceBefore);
        assertEq(mBalanceAfter, totalSupplyAfter - totalAssetsBefore);
        assertEq(usdat.assetCap(M_TOKEN), mBalanceAfter);
        assertEq(usdat.assetBalanceOf(M_TOKEN), mBalanceAfter);
        assertEq(usdat.assetDecimals(M_TOKEN), 6);

        // The USDC alt-asset backing remains and totalAssets is now the sum of the USDC + M balances.
        assertEq(usdat.assetBalanceOf(USDC), usdcBalanceBefore);
        assertEq(usdat.totalAssets(), mBalanceBefore + usdcBalanceBefore);

        // M wraps are blocked (cap == balance)
        assertFalse(usdat.isAllowedToWrap(M_TOKEN, 1));

        // PYUSDX backing is zero (all backing is M) and unwrap is blocked
        assertEq(IERC20(PYUSDX).balanceOf(USDAT_PROXY), 0);
        assertFalse(usdat.isAllowedToUnwrap(1));

        // M earning carries through the upgrade untouched — the reserves keep yielding while they are
        // drained, and that yield is realized via claimMYield.
        assertTrue(IMTokenLike(M_TOKEN).isEarning(USDAT_PROXY));

        // Reinitializer guard: migrate cannot run again
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        usdat.migrate();
    }

    /// @dev The point of leaving M earning on: yield accrues on the reserves after the upgrade, invisible
    ///      to MultiMint's balance snapshot, and `claimMYield` is the only way to realize it.
    function test_claimMYield_realizesMYieldAccruedAfterUpgrade() external {
        _doTimelockUpgrade();

        address yieldRecipient = usdat.yieldRecipient();
        uint256 totalSupplyBefore = usdat.totalSupply();
        uint256 totalAssetsBefore = usdat.totalAssets();
        uint256 trackedBefore = usdat.assetBalanceOf(M_TOKEN);
        uint256 capBefore = usdat.assetCap(M_TOKEN);
        uint256 yieldRecipientBalanceBefore = usdat.balanceOf(yieldRecipient);

        // Nothing to claim right after migrate: it registered the full held balance.
        assertEq(usdat.mYield(), 0);

        vm.warp(block.timestamp + 30 days);

        // Earning continued, so the held M outgrew the balance MultiMint tracks.
        uint256 surplus = IERC20(M_TOKEN).balanceOf(USDAT_PROXY) - trackedBefore;
        assertGt(surplus, 0);
        assertEq(usdat.mYield(), surplus);

        // Permissionless: EXECUTOR holds no role on the token.
        vm.prank(EXECUTOR);
        assertEq(usdat.claimMYield(), surplus);

        // The surplus went to the yield recipient and was registered as backing.
        assertEq(usdat.balanceOf(yieldRecipient), yieldRecipientBalanceBefore + surplus);
        assertEq(usdat.totalSupply(), totalSupplyBefore + surplus);
        assertEq(usdat.totalAssets(), totalAssetsBefore + surplus);
        assertEq(usdat.assetBalanceOf(M_TOKEN), IERC20(M_TOKEN).balanceOf(USDAT_PROXY));
        assertEq(usdat.mYield(), 0);

        // cap untouched, so M wraps stay blocked.
        assertEq(usdat.assetCap(M_TOKEN), capBefore);
        assertFalse(usdat.isAllowedToWrap(M_TOKEN, 1));
    }

    /// @dev Regression test for the hazard the timelock introduces: five days elapse between `schedule`
    ///      and `execute`, and the proxy keeps earning M throughout. `migrate` must absorb that surplus
    ///      (minting it to the yield recipient, as the legacy `claimYield` would have) rather than
    ///      revert the upgrade on a reserves mismatch. This is why no `claimYield` pre-call exists:
    ///      any amount it realized would be stale by execution time anyway.
    function test_migrate_absorbsYieldAccruedDuringTimelockDelay() external {
        (address proxyAdmin, bytes memory payload) = _schedule();

        address yieldRecipient = legacyProxy.yieldRecipient();
        uint256 totalSupplyBefore = legacyProxy.totalSupply();
        uint256 totalAssetsBefore = legacyProxy.totalAssets();
        uint256 yieldRecipientBalanceBefore = legacyProxy.balanceOf(yieldRecipient);
        uint256 yieldAtSchedule = legacyProxy.yield();

        // Yield accrues across the mandatory delay.
        vm.warp(block.timestamp + 5 days + 1);

        uint256 surplus = legacyProxy.yield();
        uint256 mBalance = IERC20(M_TOKEN).balanceOf(USDAT_PROXY);

        // The delay itself grew the surplus that migrate has to absorb.
        assertGt(surplus, yieldAtSchedule);

        _execute(proxyAdmin, payload);

        // The surplus accrued during the delay went to the yield recipient, and the full M balance was
        // registered as backing.
        assertEq(usdat.totalSupply(), totalSupplyBefore + surplus);
        assertEq(usdat.balanceOf(yieldRecipient), yieldRecipientBalanceBefore + surplus);
        assertEq(usdat.assetBalanceOf(M_TOKEN), mBalance);
        assertEq(usdat.assetCap(M_TOKEN), mBalance);
        assertEq(usdat.totalAssets(), totalAssetsBefore + mBalance);
    }

    /* ============ State preservation ============ */

    function test_upgrade_preservesHolderBalances() external {
        address holder = 0x7a7dE491e1BE5287874904e2b7c8488249A4D0a9; // Pendle: SY-USDat Token
        uint256 holderBalanceBefore = legacyProxy.balanceOf(holder);

        assertEq(holderBalanceBefore, 58_546_851_626822);

        _doTimelockUpgrade();

        assertEq(usdat.balanceOf(holder), holderBalanceBefore);
    }

    function test_upgrade_preservesRoles() external {
        _doTimelockUpgrade();

        // AccessControl storage carries over.
        assertTrue(usdat.hasRole(usdat.DEFAULT_ADMIN_ROLE(), TIMELOCK));
        assertTrue(usdat.hasRole(usdat.FREEZE_MANAGER_ROLE(), ROLE_MANAGER));
        assertTrue(usdat.hasRole(usdat.PAUSER_ROLE(), ROLE_MANAGER));
        assertTrue(usdat.hasRole(usdat.FORCED_TRANSFER_MANAGER_ROLE(), ROLE_MANAGER));
        assertTrue(usdat.hasRole(usdat.WHITELIST_MANAGER_ROLE(), ROLE_MANAGER));
        assertTrue(usdat.hasRole(usdat.YIELD_RECIPIENT_MANAGER_ROLE(), YIELD_RECIPIENT_MANAGER));
        assertTrue(usdat.hasRole(usdat.ASSET_CAP_MANAGER_ROLE(), ASSET_CAP_MANAGER));

        // VERSION_MANAGER_ROLE was never granted to anyone — and is moot, since USDat disables
        // pinVersion/unpinVersion outright (they revert VersionPinningDisabled regardless of role).
        assertFalse(usdat.hasRole(usdat.VERSION_MANAGER_ROLE(), PROPOSER));
        assertFalse(usdat.hasRole(usdat.VERSION_MANAGER_ROLE(), ROLE_MANAGER));
    }
}
