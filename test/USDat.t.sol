// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {
    IAccessControl
} from "openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import {Upgrades, UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {MockM, MockSwapFacility, MockRegistrar, MockERC20} from "m-extensions/test/utils/Mocks.sol";
import {IForcedTransferable} from "@m-extensions/components/forcedTransferable/IForcedTransferable.sol";
import {IFreezable} from "@m-extensions/components/freezable/IFreezable.sol";
import {IMExtension} from "@m-extensions/interfaces/IMExtension.sol";

import {USDat} from "../src/USDat.sol";
import {IUSDat} from "../src/IUSDat.sol";

contract USDatTest is Test {
    USDat public usdat;
    MockM public mToken;
    MockRegistrar public registrar;
    MockSwapFacility public swapFacility;

    // Role constants
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant WHITELIST_MANAGER_ROLE = keccak256("WHITELIST_MANAGER_ROLE");
    bytes32 public constant FREEZE_MANAGER_ROLE = keccak256("FREEZE_MANAGER_ROLE");
    bytes32 public constant FORCED_TRANSFER_MANAGER_ROLE = keccak256("FORCED_TRANSFER_MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant YIELD_RECIPIENT_MANAGER_ROLE = keccak256("YIELD_RECIPIENT_MANAGER_ROLE");

    // Test addresses
    address public admin = makeAddr("admin");
    address public compliance = makeAddr("compliance");
    address public processor = makeAddr("processor");
    address public yieldRecipient = makeAddr("yieldRecipient");
    address public pauser = makeAddr("pauser");

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");

    function setUp() public {
        // Deploy mocks
        mToken = new MockM();
        registrar = new MockRegistrar();

        // Deploy MockSwapFacility
        swapFacility = new MockSwapFacility();

        // Deploy USDat
        address implementation = address(new USDat(address(mToken), address(swapFacility)));
        usdat = USDat(
            UnsafeUpgrades.deployTransparentProxy(
                implementation,
                admin,
                abi.encodeWithSelector(USDat.initialize.selector, yieldRecipient, admin, compliance, processor)
            )
        );

        // Set up earner in registrar
        registrar.setEarner(address(usdat), true);

        // Set initial M token index
        mToken.setCurrentIndex(1e12);
    }

    /* ============ Initialization Tests ============ */

    function test_initialize() external view {
        assertEq(usdat.name(), "USDat");
        assertEq(usdat.symbol(), "USDat");
        assertEq(usdat.decimals(), 6);
        assertEq(usdat.mToken(), address(mToken));
        assertEq(usdat.swapFacility(), address(swapFacility));
        assertEq(usdat.yieldRecipient(), yieldRecipient);

        // Check roles
        assertTrue(usdat.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertTrue(usdat.hasRole(WHITELIST_MANAGER_ROLE, compliance));
        assertTrue(usdat.hasRole(FORCED_TRANSFER_MANAGER_ROLE, compliance));
        assertTrue(usdat.hasRole(FREEZE_MANAGER_ROLE, compliance));
        assertTrue(usdat.hasRole(PAUSER_ROLE, compliance));
        assertTrue(usdat.hasRole(YIELD_RECIPIENT_MANAGER_ROLE, processor));

        // Check initial state
        assertFalse(usdat.isWhitelistEnabled());
    }

    function test_initialize_cannotReinitialize() external {
        vm.expectRevert();
        usdat.initialize(yieldRecipient, admin, compliance, processor);
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

    /* ============ Wrap with Whitelist Tests ============ */

    function test_wrap_whitelistDisabled() external {
        uint256 amount = 1_000e6;

        // Setup: Give M to swap facility and approve
        mToken.setBalanceOf(address(swapFacility), amount);

        // Wrap should succeed without whitelist
        vm.prank(address(swapFacility));
        usdat.wrap(alice, amount);

        assertEq(usdat.balanceOf(alice), amount);
    }

    function test_wrap_whitelistEnabled_accountWhitelisted() external {
        uint256 amount = 1_000e6;

        // Enable whitelist and whitelist alice
        vm.prank(compliance);
        usdat.enableWhitelist();

        vm.prank(compliance);
        usdat.whitelist(alice);

        // Setup: Give M to swap facility
        mToken.setBalanceOf(address(swapFacility), amount);

        // Set msgSender to alice (the depositor)
        swapFacility.setMsgSender(alice);

        // Wrap should succeed
        vm.prank(address(swapFacility));
        usdat.wrap(alice, amount);

        assertEq(usdat.balanceOf(alice), amount);
    }

    function test_wrap_whitelistEnabled_accountNotWhitelisted() external {
        uint256 amount = 1_000e6;

        // Enable whitelist but don't whitelist alice
        vm.prank(compliance);
        usdat.enableWhitelist();

        // Setup: Give M to swap facility
        mToken.setBalanceOf(address(swapFacility), amount);

        // Set msgSender to alice (the depositor, not whitelisted)
        swapFacility.setMsgSender(alice);

        // Wrap should fail - alice (depositor) is not whitelisted
        vm.expectRevert(abi.encodeWithSelector(IUSDat.AccountNotWhitelisted.selector, alice));

        vm.prank(address(swapFacility));
        usdat.wrap(alice, amount);
    }

    function test_wrap_whitelistEnabled_recipientNotWhitelisted() external {
        uint256 amount = 1_000e6;

        // Enable whitelist and whitelist swap facility (caller in msgSender context)
        // but don't whitelist bob (recipient)
        vm.prank(compliance);
        usdat.enableWhitelist();

        vm.prank(compliance);
        usdat.whitelist(alice);

        // Setup
        mToken.setBalanceOf(address(swapFacility), amount);

        // Set msgSender to alice (whitelisted)
        swapFacility.setMsgSender(alice);

        // Should fail because bob (recipient) is not whitelisted
        vm.expectRevert(abi.encodeWithSelector(IUSDat.AccountNotWhitelisted.selector, bob));

        vm.prank(address(swapFacility));
        usdat.wrap(bob, amount);
    }

    /* ============ Unwrap with Whitelist Tests ============ */

    function test_unwrap_whitelistDisabled() external {
        uint256 amount = 1_000e6;

        // Setup: wrap first
        mToken.setBalanceOf(address(swapFacility), amount);
        vm.prank(address(swapFacility));
        usdat.wrap(alice, amount);

        // Give usdat some M for unwrapping
        mToken.setBalanceOf(address(usdat), amount);

        // Transfer tokens to swap facility for unwrap
        vm.prank(alice);
        usdat.transfer(address(swapFacility), amount);

        // Unwrap should succeed
        vm.prank(address(swapFacility));
        usdat.unwrap(alice, amount);

        assertEq(usdat.balanceOf(alice), 0);
    }

    function test_unwrap_whitelistEnabled_accountWhitelisted() external {
        uint256 amount = 1_000e6;

        // Setup whitelist
        vm.prank(compliance);
        usdat.whitelist(alice);

        // Setup: wrap first (whitelist disabled)
        mToken.setBalanceOf(address(swapFacility), amount);
        vm.prank(address(swapFacility));
        usdat.wrap(alice, amount);

        // Enable whitelist
        vm.prank(compliance);
        usdat.enableWhitelist();

        // Give usdat some M for unwrapping
        mToken.setBalanceOf(address(usdat), amount);

        // Transfer tokens to swap facility for unwrap
        vm.prank(alice);
        usdat.transfer(address(swapFacility), amount);

        // Set msgSender
        swapFacility.setMsgSender(alice);

        // Unwrap should succeed
        vm.prank(address(swapFacility));
        usdat.unwrap(alice, amount);

        assertEq(usdat.balanceOf(alice), 0);
    }

    function test_unwrap_whitelistEnabled_accountNotWhitelisted() external {
        uint256 amount = 1_000e6;

        // Setup: wrap first (whitelist disabled)
        mToken.setBalanceOf(address(swapFacility), amount);
        vm.prank(address(swapFacility));
        usdat.wrap(alice, amount);

        // Enable whitelist (alice not whitelisted)
        vm.prank(compliance);
        usdat.enableWhitelist();

        // Give usdat some M for unwrapping
        mToken.setBalanceOf(address(usdat), amount);

        // Transfer tokens to swap facility for unwrap
        vm.prank(alice);
        usdat.transfer(address(swapFacility), amount);

        // Set msgSender to alice (not whitelisted)
        swapFacility.setMsgSender(alice);

        // Unwrap should fail
        vm.expectRevert(abi.encodeWithSelector(IUSDat.AccountNotWhitelisted.selector, alice));

        vm.prank(address(swapFacility));
        usdat.unwrap(alice, amount);
    }

    /* ============ Forced Transfer Tests ============ */

    function test_forceTransfer_onlyForcedTransferManager() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, FORCED_TRANSFER_MANAGER_ROLE
            )
        );

        vm.prank(alice);
        usdat.forceTransfer(bob, carol, 100);
    }

    function test_forceTransfer_accountNotFrozen() external {
        // Give bob some tokens first
        mToken.setBalanceOf(address(swapFacility), 1000e6);
        vm.prank(address(swapFacility));
        usdat.wrap(bob, 1000e6);

        // Try to force transfer from non-frozen account
        vm.expectRevert(abi.encodeWithSelector(IFreezable.AccountNotFrozen.selector, bob));

        vm.prank(compliance);
        usdat.forceTransfer(bob, carol, 100e6);
    }

    function test_forceTransfer_invalidRecipient() external {
        // Give bob some tokens and freeze him
        mToken.setBalanceOf(address(swapFacility), 1000e6);
        vm.prank(address(swapFacility));
        usdat.wrap(bob, 1000e6);

        vm.prank(compliance);
        usdat.freeze(bob);

        // Try to force transfer to zero address
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("InvalidRecipient(address)")), address(0)));

        vm.prank(compliance);
        usdat.forceTransfer(bob, address(0), 100e6);
    }

    function test_forceTransfer_insufficientBalance() external {
        // Give bob some tokens and freeze him
        mToken.setBalanceOf(address(swapFacility), 100e6);
        vm.prank(address(swapFacility));
        usdat.wrap(bob, 100e6);

        vm.prank(compliance);
        usdat.freeze(bob);

        // Try to force transfer more than balance
        vm.expectRevert(abi.encodeWithSelector(IMExtension.InsufficientBalance.selector, bob, 100e6, 200e6));

        vm.prank(compliance);
        usdat.forceTransfer(bob, carol, 200e6);
    }

    function test_forceTransfer_success() external {
        uint256 amount = 1000e6;
        uint256 transferAmount = 400e6;

        // Give bob some tokens
        mToken.setBalanceOf(address(swapFacility), amount);
        vm.prank(address(swapFacility));
        usdat.wrap(bob, amount);

        // Freeze bob
        vm.prank(compliance);
        usdat.freeze(bob);

        // Force transfer
        vm.expectEmit(true, true, true, true);
        emit IForcedTransferable.ForcedTransfer(bob, carol, compliance, transferAmount);

        vm.prank(compliance);
        usdat.forceTransfer(bob, carol, transferAmount);

        assertEq(usdat.balanceOf(bob), amount - transferAmount);
        assertEq(usdat.balanceOf(carol), transferAmount);
    }

    function test_forceTransfer_zeroAmount() external {
        // Give bob some tokens
        mToken.setBalanceOf(address(swapFacility), 1000e6);
        vm.prank(address(swapFacility));
        usdat.wrap(bob, 1000e6);

        // Freeze bob
        vm.prank(compliance);
        usdat.freeze(bob);

        uint256 bobBalanceBefore = usdat.balanceOf(bob);
        uint256 carolBalanceBefore = usdat.balanceOf(carol);

        // Force transfer zero amount - should succeed but be no-op
        vm.prank(compliance);
        usdat.forceTransfer(bob, carol, 0);

        assertEq(usdat.balanceOf(bob), bobBalanceBefore);
        assertEq(usdat.balanceOf(carol), carolBalanceBefore);
    }

    function test_forceTransfers_batch() external {
        // Setup: give bob and carol tokens
        mToken.setBalanceOf(address(swapFacility), 2000e6);
        vm.prank(address(swapFacility));
        usdat.wrap(bob, 1000e6);

        mToken.setBalanceOf(address(swapFacility), 1000e6);
        vm.prank(address(swapFacility));
        usdat.wrap(carol, 1000e6);

        // Freeze both
        vm.prank(compliance);
        usdat.freeze(bob);

        vm.prank(compliance);
        usdat.freeze(carol);

        // Setup batch arrays
        address[] memory froms = new address[](2);
        address[] memory tos = new address[](2);
        uint256[] memory amounts = new uint256[](2);

        froms[0] = bob;
        froms[1] = carol;
        tos[0] = alice;
        tos[1] = alice;
        amounts[0] = 500e6;
        amounts[1] = 300e6;

        // Batch force transfer
        vm.prank(compliance);
        usdat.forceTransfers(froms, tos, amounts);

        assertEq(usdat.balanceOf(bob), 500e6);
        assertEq(usdat.balanceOf(carol), 700e6);
        assertEq(usdat.balanceOf(alice), 800e6);
    }

    function test_forceTransfers_arrayLengthMismatch() external {
        address[] memory froms = new address[](2);
        address[] memory tos = new address[](1);
        uint256[] memory amounts = new uint256[](2);

        froms[0] = bob;
        froms[1] = carol;
        tos[0] = alice;
        amounts[0] = 100e6;
        amounts[1] = 200e6;

        vm.expectRevert(IForcedTransferable.ArrayLengthMismatch.selector);

        vm.prank(compliance);
        usdat.forceTransfers(froms, tos, amounts);
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

    function test_transfer_frozenAccount() external {
        // Give alice tokens
        mToken.setBalanceOf(address(swapFacility), 1000e6);
        vm.prank(address(swapFacility));
        usdat.wrap(alice, 1000e6);

        // Freeze alice
        vm.prank(compliance);
        usdat.freeze(alice);

        // Try to transfer
        vm.expectRevert(abi.encodeWithSelector(IFreezable.AccountFrozen.selector, alice));

        vm.prank(alice);
        usdat.transfer(bob, 100e6);
    }

    /* ============ Pause Tests ============ */

    function test_pause() external {
        vm.prank(compliance);
        usdat.pause();

        assertTrue(usdat.paused());
    }

    function test_unpause() external {
        vm.prank(compliance);
        usdat.pause();

        vm.prank(compliance);
        usdat.unpause();

        assertFalse(usdat.paused());
    }

    function test_wrap_whenPaused() external {
        vm.prank(compliance);
        usdat.pause();

        mToken.setBalanceOf(address(swapFacility), 1000e6);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);

        vm.prank(address(swapFacility));
        usdat.wrap(alice, 1000e6);
    }

    function test_transfer_whenPaused() external {
        // Give alice tokens
        mToken.setBalanceOf(address(swapFacility), 1000e6);
        vm.prank(address(swapFacility));
        usdat.wrap(alice, 1000e6);

        // Pause
        vm.prank(compliance);
        usdat.pause();

        // Try to transfer
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);

        vm.prank(alice);
        usdat.transfer(bob, 100e6);
    }

    /* ============ JMI Wrap (via SwapFacility) Whitelist Tests ============ */

    function test_wrapJMI_whitelistDisabled() external {
        uint256 amount = 1_000e6;

        // Setup: Set USDC asset cap so it's allowed (processor has ASSET_CAP_MANAGER_ROLE)
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        vm.prank(processor);
        usdat.setAssetCap(address(usdc), type(uint256).max);

        // Give USDC to swap facility
        usdc.mint(address(swapFacility), amount);

        // Approve USDat to spend USDC from swap facility
        vm.prank(address(swapFacility));
        usdc.approve(address(usdat), amount);

        // JMI wrap should succeed without whitelist
        vm.prank(address(swapFacility));
        usdat.wrap(address(usdc), alice, amount);

        assertEq(usdat.balanceOf(alice), amount);
    }

    function test_wrapJMI_whitelistEnabled_accountWhitelisted() external {
        uint256 amount = 1_000e6;

        // Setup: Set USDC asset cap so it's allowed (processor has ASSET_CAP_MANAGER_ROLE)
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        vm.prank(processor);
        usdat.setAssetCap(address(usdc), type(uint256).max);

        // Enable whitelist and whitelist alice
        vm.prank(compliance);
        usdat.enableWhitelist();

        vm.prank(compliance);
        usdat.whitelist(alice);

        // Give USDC to swap facility
        usdc.mint(address(swapFacility), amount);

        // Approve USDat to spend USDC from swap facility
        vm.prank(address(swapFacility));
        usdc.approve(address(usdat), amount);

        // Set msgSender to alice (the depositor)
        swapFacility.setMsgSender(alice);

        // JMI wrap should succeed
        vm.prank(address(swapFacility));
        usdat.wrap(address(usdc), alice, amount);

        assertEq(usdat.balanceOf(alice), amount);
    }

    function test_wrapJMI_whitelistEnabled_accountNotWhitelisted() external {
        uint256 amount = 1_000e6;

        // Setup: Set USDC asset cap so it's allowed (processor has ASSET_CAP_MANAGER_ROLE)
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        vm.prank(processor);
        usdat.setAssetCap(address(usdc), type(uint256).max);

        // Enable whitelist but don't whitelist alice
        vm.prank(compliance);
        usdat.enableWhitelist();

        // Give USDC to swap facility
        usdc.mint(address(swapFacility), amount);

        // Approve USDat to spend USDC from swap facility
        vm.prank(address(swapFacility));
        usdc.approve(address(usdat), amount);

        // Set msgSender to alice (the depositor, not whitelisted)
        swapFacility.setMsgSender(alice);

        // JMI wrap should fail - alice (depositor) is not whitelisted
        vm.expectRevert(abi.encodeWithSelector(IUSDat.AccountNotWhitelisted.selector, alice));

        vm.prank(address(swapFacility));
        usdat.wrap(address(usdc), alice, amount);
    }

    function test_wrapJMI_whitelistEnabled_recipientNotWhitelisted() external {
        uint256 amount = 1_000e6;

        // Setup: Set USDC asset cap so it's allowed (processor has ASSET_CAP_MANAGER_ROLE)
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        vm.prank(processor);
        usdat.setAssetCap(address(usdc), type(uint256).max);

        // Enable whitelist and whitelist alice but not bob
        vm.prank(compliance);
        usdat.enableWhitelist();

        vm.prank(compliance);
        usdat.whitelist(alice);

        // Give USDC to swap facility
        usdc.mint(address(swapFacility), amount);

        // Approve USDat to spend USDC from swap facility
        vm.prank(address(swapFacility));
        usdc.approve(address(usdat), amount);

        // Set msgSender to alice (whitelisted)
        swapFacility.setMsgSender(alice);

        // JMI wrap should fail - bob (recipient) is not whitelisted
        vm.expectRevert(abi.encodeWithSelector(IUSDat.AccountNotWhitelisted.selector, bob));

        vm.prank(address(swapFacility));
        usdat.wrap(address(usdc), bob, amount);
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
}
