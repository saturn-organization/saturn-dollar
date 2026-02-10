// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {USDat} from "../src/USDat.sol";

interface ICreateX {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address);

    function computeCreate3Address(bytes32 salt) external view returns (address);
}

// Deployer 0x8CBA689B49f15E0a3c8770496Df8E88952d6851d
contract DeployUSDat is Script {
    ICreateX constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    function run() public {
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));

        address mToken = vm.envAddress("M_TOKEN");
        address swapFacility = vm.envAddress("SWAP_FACILITY");
        address yieldRecipient = vm.envAddress("YIELD_RECIPIENT");
        address admin = vm.envAddress("ADMIN");
        address compliance = vm.envAddress("COMPLIANCE");
        address processor = vm.envAddress("PROCESSOR");

        bytes32 proxySalt = _computeSalt(deployer, "USDat");

        console.log("Deployer:", deployer);
        console.log("Predicted proxy:", _getCreate3Address(deployer, proxySalt));

        vm.startBroadcast(deployer);

        address implementation = address(new USDat(mToken, swapFacility));

        bytes memory initData = abi.encodeCall(USDat.initialize, (yieldRecipient, admin, compliance, processor));

        address proxy = _deployCreate3TransparentProxy(implementation, admin, initData, proxySalt);

        address proxyAdmin = Upgrades.getAdminAddress(proxy);

        vm.stopBroadcast();

        console.log("Implementation:", implementation);
        console.log("Proxy:", proxy);
        console.log("ProxyAdmin:", proxyAdmin);
    }

    function _deployCreate3TransparentProxy(
        address implementation,
        address initialOwner,
        bytes memory initializerData,
        bytes32 salt
    ) internal returns (address) {
        return CREATEX.deployCreate3(
            salt,
            abi.encodePacked(
                type(TransparentUpgradeableProxy).creationCode,
                abi.encode(implementation, initialOwner, initializerData)
            )
        );
    }

    function _computeSalt(address deployer, string memory contractName) internal pure returns (bytes32) {
        return bytes32(abi.encodePacked(bytes20(deployer), bytes1(0), bytes11(keccak256(bytes(contractName)))));
    }

    function _computeGuardedSalt(address deployer, bytes32 salt) internal pure returns (bytes32) {
        return _efficientHash(bytes32(uint256(uint160(deployer))), salt);
    }

    function _efficientHash(bytes32 a, bytes32 b) internal pure returns (bytes32 hash) {
        assembly ("memory-safe") {
            mstore(0x00, a)
            mstore(0x20, b)
            hash := keccak256(0x00, 0x40)
        }
    }

    function _getCreate3Address(address deployer, bytes32 salt) internal view returns (address) {
        return CREATEX.computeCreate3Address(_computeGuardedSalt(deployer, salt));
    }
}
