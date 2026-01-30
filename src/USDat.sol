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

    /// @custom:storage-location erc7201:Saturn.storage.Supply
    struct SupplyStorage {
        bool isEnabled;
        uint256 cap;
    }

    // keccak256(abi.encode(uint256(keccak256("Saturn.storage.Supply")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _SUPPLY_STORAGE_LOCATION =
        0xb1939d04e1ce3f8ab5c30deea2bae02b0819be9d63c48182a7a9963d4ad29200;

    function _getSupplyStorage() private pure returns (SupplyStorage storage $) {
        assembly {
            $.slot := _SUPPLY_STORAGE_LOCATION
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
        if (yieldRecipient == address(0) || admin == address(0) || compliance == address(0) || processor == address(0))
        {
            revert ZeroAddress();
        }

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

    /* ============ Supply Cap Functions ============ */

    /// @inheritdoc IUSDat
    function enableSupplyCap() external onlyRole(DEFAULT_ADMIN_ROLE) {
        SupplyStorage storage $ = _getSupplyStorage();
        if ($.isEnabled) return;
        $.isEnabled = true;
        emit SupplyCapEnabled(block.timestamp);
    }

    /// @inheritdoc IUSDat
    function disableSupplyCap() external onlyRole(DEFAULT_ADMIN_ROLE) {
        SupplyStorage storage $ = _getSupplyStorage();
        if (!$.isEnabled) return;
        $.isEnabled = false;
        emit SupplyCapDisabled(block.timestamp);
    }

    /// @inheritdoc IUSDat
    function setSupplyCap(uint256 newCap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _getSupplyStorage().cap = newCap;
        emit SupplyCapUpdated(newCap);
    }

    /// @inheritdoc IUSDat
    function isSupplyCapEnabled() external view returns (bool) {
        return _getSupplyStorage().isEnabled;
    }

    /// @inheritdoc IUSDat
    function supplyCap() external view returns (uint256) {
        return _getSupplyStorage().cap;
    }

    /* ============ Internal Functions ============ */

    /**
     * @dev   Hook called before wrapping M or an allowed asset into USDat.
     *        Enforces whitelist requirements for both the depositor and recipient,
     *        and checks that the wrap amount does not exceed the supply cap.
     * @param account   The address initiating the wrap (depositor).
     * @param recipient The address that will receive the minted USDat tokens.
     * @param amount    The amount of tokens being wrapped.
     */
    function _beforeWrap(address account, address recipient, uint256 amount) internal view virtual override {
        _revertIfNotWhitelisted(account);
        _revertIfNotWhitelisted(recipient);
        _revertIfSupplyCapExceeded(amount);
        super._beforeWrap(account, recipient, amount);
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
     * @dev   Reverts if the supply cap is enabled and minting `amount` would exceed it.
     *        This check is bypassed when the supply cap feature is disabled.
     * @param amount The amount of tokens to be minted.
     */
    function _revertIfSupplyCapExceeded(uint256 amount) internal view {
        SupplyStorage storage $ = _getSupplyStorage();
        if ($.isEnabled && totalSupply() + amount > $.cap) {
            revert SupplyCapExceeded(totalSupply(), amount, $.cap);
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
