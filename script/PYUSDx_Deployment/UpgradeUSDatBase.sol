// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Options, Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IProxyAdmin} from "openzeppelin-foundry-upgrades/internal/interfaces/IProxyAdmin.sol";

import {USDat} from "../../src/USDat.sol";

/// @dev Minimal legacy surface needed to interact with the live JMIExtension implementation pre-upgrade.
///      Declared here (rather than imported) because the canonical interface is pinned to pragma 0.8.26.
interface IJMIExtensionLegacy {
    function claimYield() external returns (uint256);
    function mToken() external view returns (address);
    function swapFacility() external view returns (address);
    function yieldRecipient() external view returns (address);
    function yield() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function assetBalanceOf(address asset) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

/// @dev Single-caller overload of MultiMint's `setReplaceAssetWhitelistCaller`, declared here so
///      `abi.encodeCall` can select it unambiguously (the interface also exposes an array-batch overload).
interface ISetReplaceAssetWhitelistCaller {
    function setReplaceAssetWhitelistCaller(address caller, bool allowed) external;
}

contract UpgradeUSDatBase {
    address constant USDAT_PROXY = 0x23238f20b894f29041f48D88eE91131C395Aaa71;

    address constant M_TOKEN = 0x866A2BF4E572CbcF37D5071A7a58503Bfb36be1b;
    address constant PYUSDX = 0xeBDB0942cE16386Ab90718C7BD10C91CDb66b14d;
    address constant PYUSDX_SWAP_FACILITY = 0x0bC305e7e13113cAEd3f5486849e9518a1cC4173;

    /// @dev New USDat implementation the upgrade points at. Deployed at mainnet block 25,741,375 from
    ///      commit 30df5c2; codehash checked against a local build by `VerifyCodeHash`.
    address constant NEW_IMPLEMENTATION = 0x496a4A33b6181F4536203488d9a05AC1429E702c;

    /// @dev SaturnTimelock — owner of the USDat ProxyAdmin since block 25,284,032. An OZ TimelockController
    ///      with a 5-day minDelay. EXECUTOR_ROLE is held by address(0), so anyone may execute a matured
    ///      operation; PROPOSER_ROLE and CANCELLER_ROLE are held by 0x610182581C93687Ca03F4a8E7f124f8cEC616820.
    address constant TIMELOCK = 0xfD5782E3BFF366601da3973aE30C583dE4F08A67;

    /// @dev The asset-cap-manager SaturnTimelock — a distinct TimelockController from the upgrade TIMELOCK
    ///      above. It holds USDat's ASSET_CAP_MANAGER_ROLE. Same 5-day minDelay;
    ///      EXECUTOR_ROLE is held by address(0) (anyone may execute); PROPOSER_ROLE and
    ///      CANCELLER_ROLE are held by 0xA18f34a03788CfC566Ce5CCB21b2715f072dA3Ad.
    address constant ASSET_CAP_TIMELOCK = 0x7D343D17896D2cd87A49b4fB8872298A883f78f7;

    /// @dev The M0 solver to gate `replaceAsset` to: the sole caller allowed to drain the M reserve
    ///      into PYUSDX once the whitelist is configured.
    address constant SOLVER = 0x81D22b74FFC5aFa7F5d70404390233a8C45F3b92;

    /// @dev The operation is standalone and needs no uniqueness beyond its calldata, so both are zero.
    ///      `schedule` and `execute` must agree on them: the operation id is a hash over these fields.
    bytes32 constant PREDECESSOR = bytes32(0);
    bytes32 constant SALT = bytes32(0);

    /// @dev Deploy the new implementation. Permissionless — the timelock only gates the upgrade itself.
    function _deployImplementation() internal returns (address impl) {
        Options memory opts;
        opts.constructorData = abi.encode(PYUSDX, PYUSDX_SWAP_FACILITY);
        opts.unsafeSkipStorageCheck = true;

        // NOTE: USDat has no public initializer: it lands on an already-initialized proxy and runs the
        //       one-shot `migrate` reinitializer instead (passed as the upgradeAndCall data below).
        opts.unsafeAllow = "missing-initializer";

        impl = Upgrades.prepareUpgrade("USDat.sol", opts);
    }

    /// @dev Build the call the timelock makes on execute: ProxyAdmin.upgradeAndCall(proxy, impl, migrate()).
    function _buildUpgradeAndCallData(address impl) internal view returns (address proxyAdmin, bytes memory payload) {
        proxyAdmin = Upgrades.getAdminAddress(USDAT_PROXY);
        payload = abi.encodeCall(IProxyAdmin.upgradeAndCall, (USDAT_PROXY, impl, abi.encodeCall(USDat.migrate, ())));
    }

    /// @dev Build the call the asset-cap-manager timelock makes on execute:
    ///      USDat.setReplaceAssetWhitelistCaller(SOLVER, true). Only valid after the upgrade is live, since
    ///      this selector does not exist on the pre-upgrade JMIExtension implementation.
    function _buildWhitelistSolverData() internal pure returns (bytes memory payload) {
        payload = abi.encodeCall(ISetReplaceAssetWhitelistCaller.setReplaceAssetWhitelistCaller, (SOLVER, true));
    }
}
