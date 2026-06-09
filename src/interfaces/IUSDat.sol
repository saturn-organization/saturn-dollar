// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

/**
 * @title  IUSDat
 * @notice Interface for the USDat token contract.
 * @dev Deposit and withdraw happen through the PYUSDX SwapFacility.
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

    /// @notice Thrown when an account is not whitelisted and the whitelist is enabled.
    /// @param account The address that is not whitelisted.
    error AccountNotWhitelisted(address account);

    /// @notice Thrown by `pinVersion`/`unpinVersion` — version-pinning is disabled for USDat
    ///         (it sits behind a TransparentUpgradeableProxy, not a beacon proxy).
    error VersionPinningDisabled();

    /// @notice Thrown by `migrate` when the held M balance does not equal the M-backed portion
    ///         (`totalSupply - totalAssets`), i.e. the pre-upgrade `claimYield()` was not run and
    ///         unrealized M yield remains. Registering it would over-back the token.
    /// @param  held    The M balance the contract holds.
    /// @param  backing The expected M-backed portion (`totalSupply - totalAssets`).
    error MReservesMismatch(uint256 held, uint256 backing);

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

    /* ============ Migration ============ */

    /// @notice One-shot migration run immediately after the JMIExtension → MultiMint implementation
    ///         upgrade (atomically, as the `data` of `ProxyAdmin.upgradeAndCall`).
    /// @dev    Stops M earning (self opt-out) and registers the held M balance as a replaceable MultiMint
    ///         alt-asset (bumping `totalAssets`), so the M reserves carry over and are converted to PYUSDX
    ///         over time via `replaceAsset`. The held M must equal `totalSupply - totalAssets` (i.e. the
    ///         pre-upgrade `claimYield()` realized all M yield) or it reverts `MReservesMismatch`. Guarded
    ///         by a reinitializer so it can run exactly once.
    /// @param  mToken The legacy M token address held in reserve.
    function migrate(address mToken) external;
}
