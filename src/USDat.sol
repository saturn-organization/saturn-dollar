// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {ForcedTransferable} from "@m-extensions/components/forcedTransferable/ForcedTransferable.sol";
import {UIntMath} from "common/libs/UIntMath.sol";

import {MultiMint} from "@pyusdx/platform/projects/MultiMint.sol";

import {IMTokenLike} from "./interfaces/IMTokenLike.sol";
import {IUSDat} from "./interfaces/IUSDat.sol";

/**
 * @title  USDat
 * @notice Upgrade-only PYUSDX extension. This implementation replaces the legacy JMIExtension (M-backed)
 *         implementation behind the existing USDat TransparentUpgradeableProxy. It is never deployed fresh,
 *         so it exposes `migrate` (a reinitializer) rather than `initialize`.
 */
contract USDat is IUSDat, MultiMint, ForcedTransferable {
    /// @custom:storage-location erc7201:Saturn.storage.Whitelist
    struct WhitelistStorage {
        bool isEnabled;
        mapping(address account => bool) isWhitelisted;
    }

    // keccak256(abi.encode(uint256(keccak256("Saturn.storage.Whitelist")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _WHITELIST_STORAGE_LOCATION =
        0x1d6c3b82f2027bd0b336e517c3a50a0483eb4d2c5cd82c6a491448d31b621000;

    // NOTE: Legacy slot preserved so MultiMint storage reads/writes land on the pre-upgrade JMIExtension data.
    // keccak256(abi.encode(uint256(keccak256("M0.storage.JMIExtension")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _LEGACY_JMI_STORAGE_LOCATION =
        0x4717d46f2e033163981fa31651301a35281b6b08316965d315fd1577bad94b00;

    // NOTE: Legacy slot preserved so YieldToOne storage reads/writes land on the pre-upgrade MYieldToOne data.
    // keccak256(abi.encode(uint256(keccak256("M0.storage.MYieldToOne")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _LEGACY_YIELD_TO_ONE_STORAGE_LOCATION =
        0xee2f6fc7e2e5879b17985791e0d12536cba689bda43c77b8911497248f4af100;

    function _getWhitelistStorage() private pure returns (WhitelistStorage storage $) {
        assembly {
            $.slot := _WHITELIST_STORAGE_LOCATION
        }
    }

    /// @dev Point MultiMint storage at the pre-upgrade JMIExtension slot (layouts are append-only compatible).
    function _getMultiMintStorage() internal pure override returns (MultiMintStorage storage $) {
        assembly {
            $.slot := _LEGACY_JMI_STORAGE_LOCATION
        }
    }

    /// @dev Point YieldToOne storage at the pre-upgrade MYieldToOne slot (layouts are identical).
    function _getYieldToOneStorage() internal pure override returns (YieldToOneStorage storage $) {
        assembly {
            $.slot := _LEGACY_YIELD_TO_ONE_STORAGE_LOCATION
        }
    }

    /// @inheritdoc IUSDat
    bytes32 public constant WHITELIST_MANAGER_ROLE = keccak256("WHITELIST_MANAGER_ROLE");

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address pyusdx_, address swapFacility_) MultiMint(pyusdx_, swapFacility_) {}

    /* ============ Migration ============ */

    /// @inheritdoc IUSDat
    function migrate(address mToken) external reinitializer(2) {
        // NOTE: Self opt-out of M earning.
        IMTokenLike(mToken).stopEarning();

        // NOTE: The held M must equal the M-backed portion `totalSupply - totalAssets`.
        uint256 mBalance = IERC20(mToken).balanceOf(address(this));
        uint256 backing = totalSupply() - totalAssets();

        if (mBalance != backing) revert MReservesMismatch(mBalance, backing);

        // NOTE: Register the held M as a replaceable alt-asset.
        //       M can then be replaced with PYUSDX over time via `replaceAsset`.
        MultiMintStorage storage $ = _getMultiMintStorage();

        $.assets[mToken] = Asset({cap: mBalance, balance: UIntMath.safe240(mBalance), decimals: 6});
        $.totalAssets += mBalance;
    }

    /* ============ Version Pinning (disabled) ============ */

    /// @dev USDat sits behind a TransparentUpgradeableProxy with no origin beacon, so version-pinning is
    ///      meaningless and `unpinVersion` would zero the live implementation slot. Both are disabled.
    function pinVersion(uint256) external pure override {
        revert VersionPinningDisabled();
    }

    /// @dev Disabled — see `pinVersion`.
    function unpinVersion() external pure override {
        revert VersionPinningDisabled();
    }

    /* ============ Whitelist Functions ============ */

    /// @inheritdoc IUSDat
    function enableWhitelist() external onlyRole(WHITELIST_MANAGER_ROLE) {
        WhitelistStorage storage $ = _getWhitelistStorage();
        if ($.isEnabled) return;
        $.isEnabled = true;
        emit WhitelistEnabled(block.timestamp);
    }

    /// @inheritdoc IUSDat
    function disableWhitelist() external onlyRole(WHITELIST_MANAGER_ROLE) {
        WhitelistStorage storage $ = _getWhitelistStorage();
        if (!$.isEnabled) return;
        $.isEnabled = false;
        emit WhitelistDisabled(block.timestamp);
    }

    /// @inheritdoc IUSDat
    function whitelist(address account) external onlyRole(WHITELIST_MANAGER_ROLE) {
        WhitelistStorage storage $ = _getWhitelistStorage();
        if ($.isWhitelisted[account]) return;
        $.isWhitelisted[account] = true;
        emit Whitelisted(account, block.timestamp);
    }

    /// @inheritdoc IUSDat
    function removeFromWhitelist(address account) external onlyRole(WHITELIST_MANAGER_ROLE) {
        WhitelistStorage storage $ = _getWhitelistStorage();
        if (!$.isWhitelisted[account]) return;
        $.isWhitelisted[account] = false;
        emit RemovedFromWhitelist(account, block.timestamp);
    }

    /// @inheritdoc IUSDat
    function isWhitelistEnabled() public view returns (bool) {
        return _getWhitelistStorage().isEnabled;
    }

    /// @inheritdoc IUSDat
    function isWhitelisted(address account) public view returns (bool) {
        return _getWhitelistStorage().isWhitelisted[account];
    }

    /* ============ Internal Functions ============ */

    /**
     * @dev   Hook called before wrapping PYUSDX into USDat.
     *        Enforces whitelist requirements for both the depositor and recipient.
     * @param account   The address initiating the wrap (depositor).
     * @param recipient The address that will receive the minted USDat tokens.
     * @param amount    The amount of tokens being wrapped.
     */
    function _beforeWrap(address account, address recipient, uint256 amount) internal view virtual override {
        _revertIfNotWhitelisted(account);
        _revertIfNotWhitelisted(recipient);
        super._beforeWrap(account, recipient, amount);
    }

    /**
     * @dev   Hook called before wrapping an allowed asset (via MultiMint) into USDat.
     *        Enforces whitelist requirements for both the depositor and recipient.
     * @param asset     The address of the asset being wrapped.
     * @param account   The address initiating the wrap (depositor).
     * @param recipient The address that will receive the minted USDat tokens.
     * @param amount    The amount of tokens being wrapped.
     */
    function _beforeWrap(address asset, address account, address recipient, uint256 amount)
        internal
        view
        virtual
        override
    {
        _revertIfNotWhitelisted(account);
        _revertIfNotWhitelisted(recipient);
        super._beforeWrap(asset, account, recipient, amount);
    }

    /**
     * @dev   Hook called before unwrapping USDat back into PYUSDX.
     *        Enforces whitelist requirements for the account burning tokens.
     * @param account The address initiating the unwrap (burning USDat).
     * @param amount  The amount of USDat tokens being unwrapped.
     */
    function _beforeUnwrap(address account, uint256 amount) internal view virtual override {
        _revertIfNotWhitelisted(account);
        super._beforeUnwrap(account, amount);
    }

    /**
     * @dev   Reverts if the whitelist is enabled and the account is not whitelisted.
     *        This check is bypassed when the whitelist feature is disabled.
     * @param account The address to check for whitelist status.
     */
    function _revertIfNotWhitelisted(address account) internal view {
        WhitelistStorage storage $ = _getWhitelistStorage();
        if ($.isEnabled && !$.isWhitelisted[account]) {
            revert AccountNotWhitelisted(account);
        }
    }

    /**
     * @dev   Forcibly transfers tokens from a frozen account to a recipient.
     *        Can only be called by an authorized compliance role (via ForcedTransferable).
     *        Validates that the source account is frozen, the recipient is valid,
     *        and the frozen account has sufficient balance.
     * @param frozenAccount The frozen address from which tokens will be transferred.
     * @param recipient     The address that will receive the tokens.
     * @param amount        The amount of tokens to transfer.
     */
    function _forceTransfer(address frozenAccount, address recipient, uint256 amount) internal override {
        _revertIfNotFrozen(frozenAccount);
        _revertIfZeroAccount(recipient);

        emit Transfer(frozenAccount, recipient, amount);
        emit ForcedTransfer(frozenAccount, recipient, msg.sender, amount);

        if (amount == 0) return;

        _revertIfInsufficientBalance(frozenAccount, amount);

        _update(frozenAccount, recipient, amount);
    }
}
