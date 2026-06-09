// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {UpgradeUSDatBase} from "./UpgradeUSDatBase.sol";

contract UpgradeUSDat is Script, UpgradeUSDatBase {
    function run() public {
        address proxyAdminOwner = vm.addr(vm.envUint("PROXY_ADMIN_OWNER_PRIVATE_KEY"));

        console.log("Upgrading USDat...");
        console.log("Proxy:", USDAT_PROXY);
        console.log("ProxyAdminOwner:", proxyAdminOwner);

        vm.startBroadcast(proxyAdminOwner);

        _upgradeAndMigrate();

        vm.stopBroadcast();

        console.log("Upgrade complete!");
    }
}
