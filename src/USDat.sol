// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {JMIExtension} from "@m-extensions/projects/jmi/JMIExtension.sol";
import {ForcedTransferable} from "@m-extensions/components/forcedTransferable/ForcedTransferable.sol";
import {IMTokenLike} from "@m-extensions/interfaces/IMTokenLike.sol";

import {IUSDat} from "./IUSDat.sol";

contract USDat is IUSDat, JMIExtension, ForcedTransferable {
    /// @custom:storage-location erc7201:Saturn.storage.Whitelist
    struct WhitelistStorage {
        bool isEnabled;
        mapping(address account => bool) isWhitelisted;
    }

    // keccak256(abi.encode(uint256(keccak256("Saturn.storage.Whitelist")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _WHITELIST_STORAGE_LOCATION =
        0x1d6c3b82f2027bd0b336e517c3a50a0483eb4d2c5cd82c6a491448d31b621000;

    function _getWhitelistStorage() private pure returns (WhitelistStorage storage $) {
        assembly {
            $.slot := _WHITELIST_STORAGE_LOCATION
        }
    }

    /// @inheritdoc IUSDat
    bytes32 public constant WHITELIST_MANAGER_ROLE = keccak256("WHITELIST_MANAGER_ROLE");

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address mToken_, address swapFacility_) JMIExtension(mToken_, swapFacility_) {
        _disableInitializers();
    }

    function initialize(address yieldRecipient, address admin, address compliance, address processor)
        public
        initializer
    {
        __JMIExtension_init("USDat", "USDat", yieldRecipient, admin, processor, compliance, compliance, processor);

        __ForcedTransferable_init(compliance);
        _grantRole(WHITELIST_MANAGER_ROLE, compliance);
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
     * @dev   Hook called before wrapping M into USDat.
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
     * @dev   Hook called before wrapping an allowed asset (via JMI) into USDat.
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
     * @dev   Hook called before unwrapping USDat back into M.
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
        _revertIfInvalidRecipient(recipient);

        emit Transfer(frozenAccount, recipient, amount);
        emit ForcedTransfer(frozenAccount, recipient, msg.sender, amount);

        if (amount == 0) return;

        _revertIfInsufficientBalance(frozenAccount, amount);

        _update(frozenAccount, recipient, amount);
    }
}
