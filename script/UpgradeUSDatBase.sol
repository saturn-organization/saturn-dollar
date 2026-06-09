// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Options, Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {USDat} from "../src/USDat.sol";

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

contract UpgradeUSDatBase {
    address constant USDAT_PROXY = 0x23238f20b894f29041f48D88eE91131C395Aaa71;
    address constant M_TOKEN = 0x866A2BF4E572CbcF37D5071A7a58503Bfb36be1b;
    address constant PYUSDX = 0xeBDB0942cE16386Ab90718C7BD10C91CDb66b14d;
    address constant PYUSDX_SWAP_FACILITY = 0x0bC305e7e13113cAEd3f5486849e9518a1cC4173;

    function _upgradeAndMigrate() internal {
        // NOTE: Realize all outstanding M yield before migrating.
        IJMIExtensionLegacy(USDAT_PROXY).claimYield();

        Options memory opts;
        opts.constructorData = abi.encode(PYUSDX, PYUSDX_SWAP_FACILITY);
        opts.unsafeSkipStorageCheck = true;

        // NOTE: USDat has no public initializer: it lands on an already-initialized proxy and runs the
        //       one-shot `migrate` reinitializer instead (passed as the upgradeAndCall data below).
        opts.unsafeAllow = "missing-initializer";

        Upgrades.upgradeProxy(USDAT_PROXY, "USDat.sol", abi.encodeCall(USDat.migrate, (M_TOKEN)), opts);
    }
}
