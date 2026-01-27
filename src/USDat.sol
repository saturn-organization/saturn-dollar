// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {JMIExtension} from "@m-extensions/projects/jmi/JMIExtension.sol";
import {ForcedTransferable} from "@m-extensions/components/forcedTransferable/ForcedTransferable.sol";
import {IMTokenLike} from "@m-extensions/interfaces/IMTokenLike.sol";

import {IUSDat} from "./IUSDat.sol";

contract USDat is IUSDat, JMIExtension, ForcedTransferable {
    /* ============ Whitelist Storage ============ */

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

    /* ============ Whitelist Variables ============ */

    /// @inheritdoc IUSDat
    bytes32 public constant WHITELIST_MANAGER_ROLE = keccak256("WHITELIST_MANAGER_ROLE");

    /* ============ Constructor ============ */

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

    /* ============ Whitelist View Functions ============ */

    /// @inheritdoc IUSDat
    function isWhitelistEnabled() public view returns (bool) {
        return _getWhitelistStorage().isEnabled;
    }

    /// @inheritdoc IUSDat
    function isWhitelisted(address account) public view returns (bool) {
        return _getWhitelistStorage().isWhitelisted[account];
    }

    /* ============ External Functions ============ */

    /// @inheritdoc IUSDat
    function deposit(address asset, address recipient, uint256 amount) external {
        if (asset == mToken) {
            _wrap(msg.sender, recipient, amount);
        } else {
            _wrap(asset, msg.sender, recipient, amount);
        }
    }

    /// @inheritdoc IUSDat
    function withdraw(address recipient, uint256 amount) external {
        _revertIfInsufficientAmount(amount);
        _beforeUnwrap(msg.sender, amount);
        _revertIfInsufficientBalance(msg.sender, amount);

        _burn(msg.sender, amount);

        IMTokenLike(mToken).transfer(recipient, amount);
    }

    /* ============ Internal Functions ============ */

    function _beforeWrap(address account, address recipient, uint256 amount) internal view virtual override {
        _revertIfNotWhitelisted(account);
        _revertIfNotWhitelisted(recipient);
        super._beforeWrap(account, recipient, amount);
    }

    function _beforeUnwrap(address account, uint256 amount) internal view virtual override {
        _revertIfNotWhitelisted(account);
        super._beforeUnwrap(account, amount);
    }

    function _revertIfNotWhitelisted(address account) internal view {
        WhitelistStorage storage $ = _getWhitelistStorage();
        if ($.isEnabled && !$.isWhitelisted[account]) {
            revert AccountNotWhitelisted(account);
        }
    }

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
