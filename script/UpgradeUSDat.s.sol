// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import {USDat} from "../src/USDat.sol";

contract UpgradeUSDat is Script {
    // Existing Sepolia deployment addresses
    address constant PROXY = 0x23238f20b894f29041f48D88eE91131C395Aaa71;
    address constant PROXY_ADMIN = 0xcf1072DA5f0D127AEf99136489BAd08bFa3D1A7D;

    function run() public {
        address admin = vm.addr(vm.envUint("ADMIN_PRIVATE_KEY"));

        // Constructor args for new implementation
        address mToken = vm.envAddress("M_TOKEN");
        address swapFacility = vm.envAddress("SWAP_FACILITY");

        console.log("Upgrading USDat...");
        console.log("Proxy:", PROXY);
        console.log("ProxyAdmin:", PROXY_ADMIN);
        console.log("Admin:", admin);

        vm.startBroadcast(admin);

        // Deploy new implementation
        address newImplementation = address(new USDat(mToken, swapFacility));
        console.log("New Implementation:", newImplementation);

        // Upgrade proxy to new implementation (no initializer call needed)
        ProxyAdmin(PROXY_ADMIN)
            .upgradeAndCall(
                ITransparentUpgradeableProxy(PROXY),
                newImplementation,
                "" // empty bytes - no initializer to call
            );

        vm.stopBroadcast();

        console.log("Upgrade complete!");
    }
}
