// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

/**
 * @title  Subset of M Token interface required for source contracts.
 * @author M0 Labs
 */
interface IMTokenLike {
    /// @notice Returns whether the given account is earning.
    /// @param  account The account to check.
    /// @return Whether the account is earning.
    function isEarning(address account) external view returns (bool);
}
