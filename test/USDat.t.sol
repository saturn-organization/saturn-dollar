// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {
    IAccessControl
} from "openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {PYUSDX} from "@pyusdx/PYUSDX.sol";
import {IPYUSDX} from "@pyusdx/IPYUSDX.sol";
import {IMultiMint} from "@pyusdx/platform/projects/interfaces/IMultiMint.sol";
import {IExtension} from "@pyusdx/platform/interfaces/IExtension.sol";
import {IArrayErrors} from "@m-extensions/interfaces/IArrayErrors.sol";
import {IFreezable} from "@m-extensions/components/freezable/IFreezable.sol";

import {PYUSDXHarness} from "../lib/PYUSDX/test/harness/PYUSDXHarness.sol";
import {MockIssuerGateway} from "../lib/PYUSDX/test/mock/MockIssuerGateway.sol";
import {MockSwapFacility} from "../lib/PYUSDX/test/mock/MockSwapFacility.sol";

import {USDat} from "../src/USDat.sol";
import {IUSDat} from "../src/interfaces/IUSDat.sol";
import {USDatHarness, MockMToken} from "./USDatHarness.sol";

contract USDatTest is Test {
    USDatHarness public usdat;
    PYUSDXHarness public pyusdx;
    MockIssuerGateway public issuerGateway;
    MockSwapFacility public swapFacility;

    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant WHITELIST_MANAGER_ROLE = keccak256("WHITELIST_MANAGER_ROLE");
    bytes32 public constant FORCED_TRANSFER_MANAGER_ROLE = keccak256("FORCED_TRANSFER_MANAGER_ROLE");
    bytes32 public constant FREEZE_MANAGER_ROLE = keccak256("FREEZE_MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant ASSET_CAP_MANAGER_ROLE = keccak256("ASSET_CAP_MANAGER_ROLE");
    bytes32 public constant YIELD_RECIPIENT_MANAGER_ROLE = keccak256("YIELD_RECIPIENT_MANAGER_ROLE");
    bytes32 public constant VERSION_MANAGER_ROLE = keccak256("VERSION_MANAGER_ROLE");

    // USDat config
    address public admin = makeAddr("admin");
    address public compliance = makeAddr("compliance");
    address public processor = makeAddr("processor");
    address public yieldRecipient = makeAddr("yieldRecipient");

    // PYUSDX config
    address public pyusdxAdmin = makeAddr("pyusdxAdmin");
    address public pauser = makeAddr("pauser");
    address public freezeManager = makeAddr("freezeManager");
    address public earnerManager = makeAddr("earnerManager");
    address public rateManager = makeAddr("rateManager");

    // Actors
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public treasury = makeAddr("treasury");

    uint256 public constant AMOUNT = 1_000e6;

    function setUp() public {
        issuerGateway = new MockIssuerGateway(address(0));

        address pyusdxImpl = address(new PYUSDXHarness());
        pyusdx = PYUSDXHarness(
            UnsafeUpgrades.deployTransparentProxy(
                pyusdxImpl,
                pyusdxAdmin,
                abi.encodeCall(
                    PYUSDX.initialize,
                    (IPYUSDX.InitializeParams({
                            name: "PYUSDx",
                            symbol: "PYUSDx",
                            admin: pyusdxAdmin,
                            pauser: pauser,
                            freezeManager: freezeManager,
                            forcedTransferManager: address(1),
                            earnerManager: earnerManager,
                            rateLimitManager: rateManager,
                            issuer: address(issuerGateway)
                        }))
                )
            )
        );

        issuerGateway.setPyusdx(address(pyusdx));

        vm.prank(rateManager);
        pyusdx.setRateLimit(address(issuerGateway), type(uint128).max, 0, true);

        swapFacility = new MockSwapFacility(address(pyusdx));

        address usdatImpl = address(new USDatHarness(address(pyusdx), address(swapFacility)));
        usdat = USDatHarness(
            UnsafeUpgrades.deployTransparentProxy(
                usdatImpl,
                admin,
                abi.encodeWithSelector(USDatHarness.initialize.selector, yieldRecipient, admin, compliance, processor)
            )
        );

        vm.prank(earnerManager);
        pyusdx.setAccountInfo(address(usdat), 500, 0, address(0));
        pyusdx.setAccountRateBps(address(usdat), uint16(500));
    }

    /* ============ Helpers ============ */

    function _mintPyusdx(address to, uint256 amount) internal {
        issuerGateway.mint(to, amount);
    }

    function _wrap(address from, address recipient, uint256 amount) internal {
        _mintPyusdx(from, amount);

        vm.startPrank(from);

        pyusdx.approve(address(swapFacility), amount);
        swapFacility.swapIn(address(usdat), amount, recipient);

        vm.stopPrank();
    }

    function _unwrap(address from, address recipient, uint256 amount) internal {
        vm.startPrank(from);

        usdat.approve(address(swapFacility), amount);
        swapFacility.swapOut(address(usdat), amount, recipient);

        vm.stopPrank();
    }

    /// @dev Sets up the post-claimYield pre-migration state: supply `s` exists and the contract holds `s` M.
    function _setUpForMigration(uint256 s) internal returns (MockMToken mToken) {
        mToken = new MockMToken();
        usdat.mintForTest(alice, s);
        mToken.mint(address(usdat), s);
    }

    /* ============ initialize / roles ============ */

    function test_initialize_grantsRoles() public view {
        assertTrue(usdat.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertTrue(usdat.hasRole(WHITELIST_MANAGER_ROLE, compliance));
        assertTrue(usdat.hasRole(FORCED_TRANSFER_MANAGER_ROLE, compliance));
        assertTrue(usdat.hasRole(FREEZE_MANAGER_ROLE, compliance));
        assertTrue(usdat.hasRole(PAUSER_ROLE, compliance));
        assertTrue(usdat.hasRole(YIELD_RECIPIENT_MANAGER_ROLE, processor));
        assertTrue(usdat.hasRole(ASSET_CAP_MANAGER_ROLE, processor));

        assertEq(usdat.yieldRecipient(), yieldRecipient);
        assertEq(usdat.pyusdx(), address(pyusdx));
        assertEq(usdat.name(), "USDat");
        assertEq(usdat.symbol(), "USDat");
        assertEq(usdat.decimals(), 6);
    }

    function test_initialize_cannotReinitialize() external {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        usdat.initialize(yieldRecipient, admin, compliance, processor);
    }

    /* ============ wrap / unwrap ============ */

    function test_wrap_mintsUSDat() public {
        _wrap(alice, alice, AMOUNT);

        assertEq(usdat.balanceOf(alice), AMOUNT);
        assertEq(usdat.totalSupply(), AMOUNT);
        assertEq(pyusdx.balanceOf(address(usdat)), AMOUNT);
    }

    function test_unwrap_returnsPyusdx() public {
        _wrap(alice, alice, AMOUNT);
        _unwrap(alice, alice, AMOUNT);

        assertEq(usdat.balanceOf(alice), 0);
        assertEq(usdat.totalSupply(), 0);
        assertEq(pyusdx.balanceOf(alice), AMOUNT);
    }

    /* ============ whitelist gating ============ */

    function test_wrap_revertsWhenRecipientNotWhitelisted() public {
        vm.prank(compliance);
        usdat.enableWhitelist();

        _mintPyusdx(alice, AMOUNT);

        vm.startPrank(alice);

        pyusdx.approve(address(swapFacility), AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(IUSDat.AccountNotWhitelisted.selector, alice));
        swapFacility.swapIn(address(usdat), AMOUNT, alice);

        vm.stopPrank();
    }

    function test_wrap_succeedsWhenWhitelisted() public {
        vm.startPrank(compliance);

        usdat.enableWhitelist();
        usdat.whitelist(alice);

        vm.stopPrank();

        _wrap(alice, alice, AMOUNT);

        assertEq(usdat.balanceOf(alice), AMOUNT);
    }

    function test_unwrap_revertsWhenNotWhitelisted() public {
        _wrap(alice, alice, AMOUNT);

        vm.prank(compliance);
        usdat.enableWhitelist();

        vm.startPrank(alice);

        usdat.approve(address(swapFacility), AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(IUSDat.AccountNotWhitelisted.selector, alice));
        swapFacility.swapOut(address(usdat), AMOUNT, alice);

        vm.stopPrank();
    }

    /* ============ forced transfer ============ */

    function test_forceTransfer_seizesFromFrozenAccount() public {
        _wrap(alice, alice, AMOUNT);

        vm.prank(compliance);
        usdat.freeze(alice);

        vm.prank(compliance);
        usdat.forceTransfer(alice, bob, AMOUNT);

        assertEq(usdat.balanceOf(alice), 0);
        assertEq(usdat.balanceOf(bob), AMOUNT);
    }

    function test_forceTransfer_revertsWhenNotFrozen() public {
        _wrap(alice, alice, AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(IFreezable.AccountNotFrozen.selector, alice));

        vm.prank(compliance);
        usdat.forceTransfer(alice, bob, AMOUNT);
    }

    function test_forceTransfer_revertsForNonManager() public {
        _wrap(alice, alice, AMOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, bob, FORCED_TRANSFER_MANAGER_ROLE
            )
        );

        vm.prank(bob);
        usdat.forceTransfer(alice, bob, AMOUNT);
    }

    /* ============ claimYield permissioning ============ */

    function test_claimYield_revertsForNonManager() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, bob, YIELD_RECIPIENT_MANAGER_ROLE
            )
        );

        vm.prank(bob);
        usdat.claimYield();
    }

    function test_claimYield_succeedsForManager() public {
        _wrap(alice, alice, AMOUNT);

        vm.warp(block.timestamp + 365 days);

        uint256 balanceBefore = usdat.balanceOf(yieldRecipient);

        vm.prank(processor);
        uint256 yield = usdat.claimYield();

        assertEq(usdat.balanceOf(yieldRecipient), balanceBefore + yield);
    }

    /* ============ version pinning disabled ============ */

    function test_pinVersion_revertsForEveryone() public {
        vm.expectRevert(IUSDat.VersionPinningDisabled.selector);

        vm.prank(admin); // holds VERSION_MANAGER_ROLE, yet still reverts (the override, not the role check)
        usdat.pinVersion(1);

        vm.expectRevert(IUSDat.VersionPinningDisabled.selector);

        vm.prank(bob);
        usdat.pinVersion(1);
    }

    function test_unpinVersion_revertsForEveryone() public {
        vm.expectRevert(IUSDat.VersionPinningDisabled.selector);

        vm.prank(admin);
        usdat.unpinVersion();

        vm.expectRevert(IUSDat.VersionPinningDisabled.selector);

        vm.prank(bob);
        usdat.unpinVersion();
    }

    /* ============ migrate ============ */

    function test_migrate_registersM() public {
        MockMToken mToken = _setUpForMigration(AMOUNT);

        usdat.migrate(address(mToken));

        assertEq(usdat.assetCap(address(mToken)), AMOUNT);
        assertEq(usdat.assetBalanceOf(address(mToken)), AMOUNT);
        assertEq(usdat.assetDecimals(address(mToken)), 6);
        assertEq(usdat.totalAssets(), AMOUNT);
        assertEq(usdat.totalSupply(), AMOUNT); // unchanged (no mint)
        assertFalse(usdat.isAllowedToUnwrap(1)); // _pyusdxBacking() == 0
    }

    function test_migrate_cannotRunTwice() public {
        MockMToken mToken = _setUpForMigration(AMOUNT);
        usdat.migrate(address(mToken));

        // reinitializer(2) guard
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        usdat.migrate(address(mToken));
    }

    function test_migrate_revertsOnReservesMismatch() public {
        MockMToken mToken = _setUpForMigration(AMOUNT);
        mToken.mint(address(usdat), 1); // mBalance = AMOUNT + 1, backing = AMOUNT

        vm.expectRevert(abi.encodeWithSelector(IUSDat.MReservesMismatch.selector, AMOUNT + 1, AMOUNT));
        usdat.migrate(address(mToken));
    }

    function test_migrate_blocksMWraps() public {
        MockMToken mToken = _setUpForMigration(AMOUNT);
        usdat.migrate(address(mToken));

        // cap == balance ⇒ no room to wrap M in
        assertFalse(usdat.isAllowedToWrap(address(mToken), 1));
    }

    /* ============ replaceAsset drain ============ */

    function test_replaceAsset_drainsMForPyusdx() public {
        MockMToken mToken = _setUpForMigration(AMOUNT);
        usdat.migrate(address(mToken));

        // whitelist treasury as a replaceAsset caller
        vm.prank(processor);
        usdat.setReplaceAssetWhitelistCaller(treasury, true);

        uint256 drain = 400e6;
        _mintPyusdx(treasury, drain);

        vm.startPrank(treasury);

        pyusdx.approve(address(swapFacility), drain);
        swapFacility.replaceAsset(address(usdat), address(mToken), drain, treasury);

        vm.stopPrank();

        assertEq(usdat.assetBalanceOf(address(mToken)), AMOUNT - drain);
        assertEq(usdat.totalAssets(), AMOUNT - drain);
        assertEq(mToken.balanceOf(treasury), drain); // treasury received M
        assertEq(pyusdx.balanceOf(address(usdat)), drain); // PYUSDX reserves built
        assertTrue(usdat.isAllowedToUnwrap(drain)); // backing grew to `drain`
    }

    function test_replaceAsset_revertsForNonWhitelistedCaller() public {
        MockMToken mToken = _setUpForMigration(AMOUNT);
        usdat.migrate(address(mToken));

        // whitelist someone else so the whitelist is non-empty (enforced)
        vm.prank(processor);
        usdat.setReplaceAssetWhitelistCaller(bob, true);

        uint256 drain = 100e6;
        _mintPyusdx(treasury, drain);

        vm.startPrank(treasury);

        pyusdx.approve(address(swapFacility), drain);

        vm.expectRevert(abi.encodeWithSelector(IMultiMint.CallerNotAllowed.selector, treasury));
        swapFacility.replaceAsset(address(usdat), address(mToken), drain, treasury);

        vm.stopPrank();
    }

    /* ============ Whitelist Enable/Disable Tests ============ */

    function test_enableWhitelist() external {
        assertFalse(usdat.isWhitelistEnabled());

        vm.expectEmit(true, true, true, true);
        emit IUSDat.WhitelistEnabled(block.timestamp);

        vm.prank(compliance);
        usdat.enableWhitelist();

        assertTrue(usdat.isWhitelistEnabled());
    }

    function test_enableWhitelist_onlyWhitelistManager() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, WHITELIST_MANAGER_ROLE
            )
        );

        vm.prank(alice);
        usdat.enableWhitelist();
    }

    function test_enableWhitelist_idempotent() external {
        vm.prank(compliance);
        usdat.enableWhitelist();

        assertTrue(usdat.isWhitelistEnabled());

        // Should not emit event when already enabled
        vm.recordLogs();
        vm.prank(compliance);
        usdat.enableWhitelist();

        assertEq(vm.getRecordedLogs().length, 0);
        assertTrue(usdat.isWhitelistEnabled());
    }

    function test_disableWhitelist() external {
        vm.prank(compliance);
        usdat.enableWhitelist();
        assertTrue(usdat.isWhitelistEnabled());

        vm.expectEmit(true, true, true, true);
        emit IUSDat.WhitelistDisabled(block.timestamp);

        vm.prank(compliance);
        usdat.disableWhitelist();

        assertFalse(usdat.isWhitelistEnabled());
    }

    function test_disableWhitelist_onlyWhitelistManager() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, WHITELIST_MANAGER_ROLE
            )
        );

        vm.prank(alice);
        usdat.disableWhitelist();
    }

    function test_disableWhitelist_idempotent() external {
        assertFalse(usdat.isWhitelistEnabled());

        // Should not emit event when already disabled
        vm.recordLogs();
        vm.prank(compliance);
        usdat.disableWhitelist();

        assertEq(vm.getRecordedLogs().length, 0);
        assertFalse(usdat.isWhitelistEnabled());
    }

    /* ============ Whitelist Add/Remove Tests ============ */

    function test_whitelist() external {
        assertFalse(usdat.isWhitelisted(alice));

        vm.expectEmit(true, true, true, true);
        emit IUSDat.Whitelisted(alice, block.timestamp);

        vm.prank(compliance);
        usdat.whitelist(alice);

        assertTrue(usdat.isWhitelisted(alice));
    }

    function test_whitelist_onlyWhitelistManager() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, WHITELIST_MANAGER_ROLE
            )
        );

        vm.prank(alice);
        usdat.whitelist(bob);
    }

    function test_whitelist_idempotent() external {
        vm.prank(compliance);
        usdat.whitelist(alice);

        assertTrue(usdat.isWhitelisted(alice));

        // Should not emit event when already whitelisted
        vm.recordLogs();
        vm.prank(compliance);
        usdat.whitelist(alice);

        assertEq(vm.getRecordedLogs().length, 0);
        assertTrue(usdat.isWhitelisted(alice));
    }

    function test_removeFromWhitelist() external {
        vm.prank(compliance);
        usdat.whitelist(alice);
        assertTrue(usdat.isWhitelisted(alice));

        vm.expectEmit(true, true, true, true);
        emit IUSDat.RemovedFromWhitelist(alice, block.timestamp);

        vm.prank(compliance);
        usdat.removeFromWhitelist(alice);

        assertFalse(usdat.isWhitelisted(alice));
    }

    function test_removeFromWhitelist_onlyWhitelistManager() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, WHITELIST_MANAGER_ROLE
            )
        );

        vm.prank(alice);
        usdat.removeFromWhitelist(bob);
    }

    function test_removeFromWhitelist_idempotent() external {
        assertFalse(usdat.isWhitelisted(alice));

        // Should not emit event when not whitelisted
        vm.recordLogs();
        vm.prank(compliance);
        usdat.removeFromWhitelist(alice);

        assertEq(vm.getRecordedLogs().length, 0);
        assertFalse(usdat.isWhitelisted(alice));
    }

    /* ============ Forced Transfer Extended Tests ============ */

    function test_forceTransfer_zeroAmount() external {
        _wrap(alice, alice, AMOUNT);

        vm.prank(compliance);
        usdat.freeze(alice);

        uint256 aliceBefore = usdat.balanceOf(alice);
        uint256 bobBefore = usdat.balanceOf(bob);

        // Force transfer zero amount - should succeed but be no-op
        vm.prank(compliance);
        usdat.forceTransfer(alice, bob, 0);

        assertEq(usdat.balanceOf(alice), aliceBefore);
        assertEq(usdat.balanceOf(bob), bobBefore);
    }

    function test_forceTransfers_batch() external {
        _wrap(alice, alice, AMOUNT);
        _wrap(bob, bob, AMOUNT);

        vm.prank(compliance);
        usdat.freeze(alice);

        vm.prank(compliance);
        usdat.freeze(bob);

        // Setup batch arrays
        address[] memory froms = new address[](2);
        address[] memory tos = new address[](2);
        uint256[] memory amounts = new uint256[](2);

        froms[0] = alice;
        froms[1] = bob;
        tos[0] = treasury;
        tos[1] = treasury;
        amounts[0] = 400e6;
        amounts[1] = 300e6;

        vm.prank(compliance);
        usdat.forceTransfers(froms, tos, amounts);

        assertEq(usdat.balanceOf(alice), AMOUNT - 400e6);
        assertEq(usdat.balanceOf(bob), AMOUNT - 300e6);
        assertEq(usdat.balanceOf(treasury), 700e6);
    }

    function test_forceTransfers_arrayLengthMismatch() external {
        address[] memory froms = new address[](2);
        address[] memory tos = new address[](1);
        uint256[] memory amounts = new uint256[](2);

        froms[0] = alice;
        froms[1] = bob;
        tos[0] = treasury;
        amounts[0] = 100e6;
        amounts[1] = 200e6;

        vm.expectRevert(IArrayErrors.ArrayLengthMismatch.selector);

        vm.prank(compliance);
        usdat.forceTransfers(froms, tos, amounts);
    }

    function test_forceTransfer_revertsOnZeroRecipient() external {
        _wrap(alice, alice, AMOUNT);

        vm.prank(compliance);
        usdat.freeze(alice);

        vm.expectRevert(IExtension.ZeroAccount.selector);

        vm.prank(compliance);
        usdat.forceTransfer(alice, address(0), AMOUNT);
    }

    function test_forceTransfer_revertsOnInsufficientBalance() external {
        _wrap(alice, alice, AMOUNT);

        vm.prank(compliance);
        usdat.freeze(alice);

        vm.expectRevert(abi.encodeWithSelector(IExtension.InsufficientBalance.selector, alice, AMOUNT, AMOUNT + 1));

        vm.prank(compliance);
        usdat.forceTransfer(alice, bob, AMOUNT + 1);
    }

    /* ============ Freeze Tests ============ */

    function test_freeze() external {
        assertFalse(usdat.isFrozen(alice));

        vm.prank(compliance);
        usdat.freeze(alice);

        assertTrue(usdat.isFrozen(alice));
    }

    function test_freeze_onlyFreezeManager() external {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, FREEZE_MANAGER_ROLE)
        );

        vm.prank(alice);
        usdat.freeze(bob);
    }

    function test_unfreeze() external {
        vm.prank(compliance);
        usdat.freeze(alice);
        assertTrue(usdat.isFrozen(alice));

        vm.prank(compliance);
        usdat.unfreeze(alice);

        assertFalse(usdat.isFrozen(alice));
    }

    function test_transfer_revertsWhenSenderFrozen() external {
        _wrap(alice, alice, AMOUNT);

        vm.prank(compliance);
        usdat.freeze(alice);

        vm.expectRevert(abi.encodeWithSelector(IFreezable.AccountFrozen.selector, alice));

        vm.prank(alice);
        usdat.transfer(bob, AMOUNT);
    }

    /* ============ Pause Tests ============ */

    function test_pause() external {
        assertFalse(usdat.paused());

        vm.prank(compliance);
        usdat.pause();

        assertTrue(usdat.paused());
    }

    function test_unpause() external {
        vm.prank(compliance);
        usdat.pause();

        assertTrue(usdat.paused());

        vm.prank(compliance);
        usdat.unpause();

        assertFalse(usdat.paused());
    }

    function test_pause_onlyPauser() external {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, PAUSER_ROLE)
        );

        vm.prank(alice);
        usdat.pause();
    }

    function test_wrap_revertsWhenPaused() external {
        vm.prank(compliance);
        usdat.pause();

        _mintPyusdx(alice, AMOUNT);

        vm.startPrank(alice);
        pyusdx.approve(address(swapFacility), AMOUNT);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        swapFacility.swapIn(address(usdat), AMOUNT, alice);

        vm.stopPrank();
    }

    function test_transfer_revertsWhenPaused() external {
        _wrap(alice, alice, AMOUNT);

        vm.prank(compliance);
        usdat.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);

        vm.prank(alice);
        usdat.transfer(bob, AMOUNT);
    }

    /* ============ Fuzz Tests ============ */

    function testFuzz_whitelist_addRemove(address account) external {
        vm.assume(account != address(0));

        assertFalse(usdat.isWhitelisted(account));

        vm.prank(compliance);
        usdat.whitelist(account);

        assertTrue(usdat.isWhitelisted(account));

        vm.prank(compliance);
        usdat.removeFromWhitelist(account);

        assertFalse(usdat.isWhitelisted(account));
    }

    /* ============ Wrap with Whitelist Tests ============ */

    function test_wrap_whitelistDisabled_succeeds() external {
        assertFalse(usdat.isWhitelistEnabled());

        _wrap(alice, alice, AMOUNT);

        assertEq(usdat.balanceOf(alice), AMOUNT);
    }

    function test_wrap_whitelistEnabled_accountWhitelisted_succeeds() external {
        vm.startPrank(compliance);

        usdat.enableWhitelist();
        usdat.whitelist(alice);

        vm.stopPrank();

        _wrap(alice, alice, AMOUNT);

        assertEq(usdat.balanceOf(alice), AMOUNT);
    }

    function test_wrap_whitelistEnabled_accountNotWhitelisted_reverts() external {
        vm.prank(compliance);
        usdat.enableWhitelist();

        _mintPyusdx(alice, AMOUNT);

        vm.startPrank(alice);
        pyusdx.approve(address(swapFacility), AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(IUSDat.AccountNotWhitelisted.selector, alice));
        swapFacility.swapIn(address(usdat), AMOUNT, alice);

        vm.stopPrank();
    }

    function test_wrap_whitelistEnabled_recipientNotWhitelisted_reverts() external {
        vm.startPrank(compliance);

        usdat.enableWhitelist();
        usdat.whitelist(alice);

        vm.stopPrank();

        _mintPyusdx(alice, AMOUNT);

        vm.startPrank(alice);

        pyusdx.approve(address(swapFacility), AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(IUSDat.AccountNotWhitelisted.selector, bob));
        swapFacility.swapIn(address(usdat), AMOUNT, bob);

        vm.stopPrank();
    }

    /* ============ Unwrap with Whitelist Tests ============ */

    function test_unwrap_whitelistDisabled_succeeds() external {
        assertFalse(usdat.isWhitelistEnabled());

        _wrap(alice, alice, AMOUNT);
        _unwrap(alice, alice, AMOUNT);

        assertEq(usdat.balanceOf(alice), 0);
        assertEq(pyusdx.balanceOf(alice), AMOUNT);
    }

    function test_unwrap_whitelistEnabled_accountWhitelisted_succeeds() external {
        _wrap(alice, alice, AMOUNT);

        vm.startPrank(compliance);

        usdat.enableWhitelist();
        usdat.whitelist(alice);

        vm.stopPrank();

        _unwrap(alice, alice, AMOUNT);

        assertEq(usdat.balanceOf(alice), 0);
        assertEq(pyusdx.balanceOf(alice), AMOUNT);
    }

    function test_unwrap_whitelistEnabled_accountNotWhitelisted_reverts() external {
        _wrap(alice, alice, AMOUNT);

        vm.prank(compliance);
        usdat.enableWhitelist();

        vm.startPrank(alice);

        usdat.approve(address(swapFacility), AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(IUSDat.AccountNotWhitelisted.selector, alice));
        swapFacility.swapOut(address(usdat), AMOUNT, alice);

        vm.stopPrank();
    }
}
