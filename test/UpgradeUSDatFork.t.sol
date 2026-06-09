// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {USDat} from "../src/USDat.sol";
import {IUSDat} from "../src/interfaces/IUSDat.sol";
import {UpgradeUSDatBase, IJMIExtensionLegacy} from "../script/UpgradeUSDatBase.sol";
import {IMTokenLike} from "../src/interfaces/IMTokenLike.sol";

contract UpgradeUSDatForkTest is Test, UpgradeUSDatBase {
    address constant M_SWAP_FACILITY = 0xB6807116b3B1B321a390594e31ECD6e0076f6278;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant PROXY_ADMIN_OWNER = 0x610182581C93687Ca03F4a8E7f124f8cEC616820;

    // Live role holders at the fork block, granted during the original JMIExtension deploy. PROXY_ADMIN_OWNER
    // additionally holds DEFAULT_ADMIN_ROLE.
    address constant ROLE_MANAGER = 0x10D59F776db12b4B271b2609CB8b7Ddd0A82703B; // freeze/pause/forced-transfer/whitelist
    address constant YIELD_RECIPIENT_MANAGER = 0x09D6E34cE24D54890fF0BC6a090b5f880F8C729f;
    address constant ASSET_CAP_MANAGER = 0x7D343D17896D2cd87A49b4fB8872298A883f78f7;

    // The same proxy, viewed through its pre-upgrade (JMIExtension) and post-upgrade (USDat) interfaces.
    IJMIExtensionLegacy public legacyProxy = IJMIExtensionLegacy(USDAT_PROXY);
    USDat public usdat = USDat(USDAT_PROXY);

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 25_280_870);
    }

    /// @dev Runs the shared upgrade codepath as the ProxyAdmin owner.
    function _upgradeAndMigrateAsOwner() internal {
        vm.startPrank(PROXY_ADMIN_OWNER);
        _upgradeAndMigrate();
        vm.stopPrank();
    }

    /* ============ Pre-upgrade state checks ============ */

    function test_preUpgrade_state() external {
        uint256 usdcBalance = 100_000001;

        assertEq(legacyProxy.mToken(), M_TOKEN);
        assertEq(legacyProxy.swapFacility(), M_SWAP_FACILITY);
        assertEq(legacyProxy.totalSupply(), 122_337_733_118939);
        assertEq(legacyProxy.totalAssets(), usdcBalance);
        assertEq(IERC20(USDC).balanceOf(USDAT_PROXY), usdcBalance);
        assertEq(legacyProxy.assetBalanceOf(USDC), usdcBalance);

        uint256 mBalance = IERC20(M_TOKEN).balanceOf(USDAT_PROXY);
        uint256 mBacking = legacyProxy.totalSupply() - legacyProxy.totalAssets() + legacyProxy.yield();

        assertEq(mBalance, mBacking);
    }

    /* ============ Full upgrade + migrate flow ============ */

    function test_upgradeAndMigrate() external {
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

        // The proxy earns M yield pre-upgrade; migrate must stop it.
        assertTrue(IMTokenLike(M_TOKEN).isEarning(USDAT_PROXY));

        // Upgrade + migrate
        _upgradeAndMigrateAsOwner();

        // Verify the script realized the pending yield
        uint256 totalSupplyAfter = totalSupplyBefore + pendingYield;
        uint256 mBalanceAfter = IERC20(M_TOKEN).balanceOf(USDAT_PROXY);

        assertEq(usdat.totalSupply(), totalSupplyAfter);
        assertEq(usdat.balanceOf(yieldRecipient), yieldRecipientBalanceBefore + pendingYield);

        // Verify post-migration state

        // The new implementation is wired to PYUSDX, not the legacy M swap facility.
        assertEq(usdat.pyusdx(), PYUSDX);
        assertEq(usdat.swapFacility(), PYUSDX_SWAP_FACILITY);

        // claimYield mints the extension token (not M), so the proxy's held M is unchanged; migrate then
        // registers that held M as a replaceable alt-asset with 6 decimals.
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

        // M earning is stopped for the proxy (migrate self opt-out)
        assertFalse(IMTokenLike(M_TOKEN).isEarning(USDAT_PROXY));

        // Reinitializer guard: migrate cannot run again
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        usdat.migrate(M_TOKEN);
    }

    function test_upgrade_preservesHolderBalances() external {
        address holder = 0x7a7dE491e1BE5287874904e2b7c8488249A4D0a9; // Pendle: SY-USDat Token
        uint256 holderBalanceBefore = legacyProxy.balanceOf(holder);

        assertEq(holderBalanceBefore, 58_745_630_170210);

        _upgradeAndMigrateAsOwner();

        assertEq(usdat.balanceOf(holder), holderBalanceBefore);
    }

    function test_upgrade_preservesRoles() external {
        _upgradeAndMigrateAsOwner();

        // AccessControl storage carries over.
        assertTrue(usdat.hasRole(usdat.DEFAULT_ADMIN_ROLE(), PROXY_ADMIN_OWNER));
        assertTrue(usdat.hasRole(usdat.FREEZE_MANAGER_ROLE(), ROLE_MANAGER));
        assertTrue(usdat.hasRole(usdat.PAUSER_ROLE(), ROLE_MANAGER));
        assertTrue(usdat.hasRole(usdat.FORCED_TRANSFER_MANAGER_ROLE(), ROLE_MANAGER));
        assertTrue(usdat.hasRole(usdat.WHITELIST_MANAGER_ROLE(), ROLE_MANAGER));
        assertTrue(usdat.hasRole(usdat.YIELD_RECIPIENT_MANAGER_ROLE(), YIELD_RECIPIENT_MANAGER));
        assertTrue(usdat.hasRole(usdat.ASSET_CAP_MANAGER_ROLE(), ASSET_CAP_MANAGER));

        // VERSION_MANAGER_ROLE was never granted to anyone — and is moot, since USDat disables
        // pinVersion/unpinVersion outright (they revert VersionPinningDisabled regardless of role).
        assertFalse(usdat.hasRole(usdat.VERSION_MANAGER_ROLE(), PROXY_ADMIN_OWNER));
        assertFalse(usdat.hasRole(usdat.VERSION_MANAGER_ROLE(), ROLE_MANAGER));
    }
}
