// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/**
 * @title  IUSDat
 * @notice Interface for the USDat token contract.
 */
interface IUSDat {
    /* ============ Events ============ */

    /// @notice Emitted when the whitelist is enabled.
    /// @param timestamp The block timestamp when the whitelist was enabled.
    event WhitelistEnabled(uint256 timestamp);

    /// @notice Emitted when the whitelist is disabled.
    /// @param timestamp The block timestamp when the whitelist was disabled.
    event WhitelistDisabled(uint256 timestamp);

    /// @notice Emitted when an account is added to the whitelist.
    /// @param account The address that was whitelisted.
    /// @param timestamp The block timestamp when the account was whitelisted.
    event Whitelisted(address indexed account, uint256 timestamp);

    /// @notice Emitted when an account is removed from the whitelist.
    /// @param account The address that was removed from the whitelist.
    /// @param timestamp The block timestamp when the account was removed.
    event RemovedFromWhitelist(address indexed account, uint256 timestamp);

    /* ============ Errors ============ */

    /// @notice Thrown when a zero address is provided during initialization.
    error ZeroAddress();

    /// @notice Thrown when an account is not whitelisted and the whitelist is enabled.
    /// @param account The address that is not whitelisted.
    error AccountNotWhitelisted(address account);

    /* ============ Whitelist Admin Functions ============ */

    /// @notice Enables the whitelist. Only whitelisted addresses can deposit when enabled.
    /// @dev    Only callable by accounts with the WHITELIST_MANAGER_ROLE.
    function enableWhitelist() external;

    /// @notice Disables the whitelist. All addresses can deposit when disabled.
    /// @dev    Only callable by accounts with the WHITELIST_MANAGER_ROLE.
    function disableWhitelist() external;

    /// @notice Adds an account to the whitelist.
    /// @dev    Only callable by accounts with the WHITELIST_MANAGER_ROLE.
    /// @param  account The address to add to the whitelist.
    function whitelist(address account) external;

    /// @notice Removes an account from the whitelist.
    /// @dev    Only callable by accounts with the WHITELIST_MANAGER_ROLE.
    /// @param  account The address to remove from the whitelist.
    function removeFromWhitelist(address account) external;

    /* ============ Whitelist View Functions ============ */

    /// @notice Returns the role identifier for the whitelist manager.
    /// @return The bytes32 role identifier.
    function WHITELIST_MANAGER_ROLE() external view returns (bytes32);

    /// @notice Returns whether the whitelist is currently enabled.
    /// @return True if the whitelist is enabled, false otherwise.
    function isWhitelistEnabled() external view returns (bool);

    /// @notice Returns whether an account is whitelisted.
    /// @param  account The address to check.
    /// @return True if the account is whitelisted, false otherwise.
    function isWhitelisted(address account) external view returns (bool);

    /* ============ Deposit/Withdraw Functions ============ */

    /// @notice Deposit assets directly into the contract to mint USDat tokens.
    /// @dev    For M token deposits, use the mToken address as the asset parameter.
    ///         For other assets, the asset must be an allowed asset with sufficient cap.
    ///         If whitelist is enabled, both the caller and recipient must be whitelisted.
    /// @param  asset The address of the asset to deposit (use mToken address for M).
    /// @param  recipient The address to receive USDat tokens.
    /// @param  amount The amount of tokens to deposit (in asset decimals).
    function deposit(address asset, address recipient, uint256 amount) external;

    /// @notice Withdraw M tokens by burning USDat tokens.
    /// @dev    Burns USDat from the caller and transfers M to the recipient.
    ///         Only M can be withdrawn; other backing assets cannot be redeemed directly.
    /// @param  recipient The address to receive M tokens.
    /// @param  amount The amount of USDat to burn.
    function withdraw(address recipient, uint256 amount) external;
}
