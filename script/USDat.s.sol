// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {
    TransparentUpgradeableProxy
} from "openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {ICreateXLike} from "common/script/deploy/interfaces/ICreateXLike.sol";

import {USDat} from "../src/USDat.sol";

/**
 * @title  DeployUSDat
 * @notice Deployment script for the USDat token contract.
 * @dev    Deploys USDat implementation and proxy using CREATE3 for deterministic addresses.
 *
 *         Required environment variables:
 *         - PRIVATE_KEY: Deployer's private key
 *         - M_TOKEN: Address of the M token
 *         - SWAP_FACILITY: Address of the SwapFacility contract
 *         - YIELD_RECIPIENT: Address that receives yield from M
 *         - ADMIN: Address that receives DEFAULT_ADMIN_ROLE
 *         - COMPLIANCE: Address that receives WHITELIST_MANAGER_ROLE and FORCED_TRANSFER_MANAGER_ROLE
 *         - PROCESSOR: Address that receives freeze manager and yield recipient manager roles
 *
 *         Optional environment variables:
 *         - PREDICTED_ADDRESS: If set, verifies the computed address matches before deployment
 *
 *         Usage:
 *         forge script script/USDat.s.sol:DeployUSDat --rpc-url $RPC_URL --broadcast --verify
 */
contract DeployUSDat is Script {
    /// @dev CreateX factory address (same across all EVM chains)
    address public constant CREATE_X_FACTORY = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;

    /// @dev Contract name used for CREATE3 salt computation
    string public constant CONTRACT_NAME = "USDat";

    /**
     * @notice Main deployment entrypoint.
     */
    function run() public {
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));

        // Load configuration from environment
        address mToken = vm.envAddress("M_TOKEN");
        address swapFacility = vm.envAddress("SWAP_FACILITY");
        address yieldRecipient = vm.envAddress("YIELD_RECIPIENT");
        address admin = vm.envAddress("ADMIN");
        address compliance = vm.envAddress("COMPLIANCE");
        address processor = vm.envAddress("PROCESSOR");

        console.log("=======================================================");
        console.log("USDat Deployment");
        console.log("=======================================================");
        console.log("Deployer:        ", deployer);
        console.log("M Token:         ", mToken);
        console.log("Swap Facility:   ", swapFacility);
        console.log("Yield Recipient: ", yieldRecipient);
        console.log("Admin:           ", admin);
        console.log("Compliance:      ", compliance);
        console.log("Processor:       ", processor);
        console.log("=======================================================");

        // Verify predicted address if provided
        if (_shouldVerifyPredictedAddress()) {
            _verifyPredictedAddress(deployer);
        }

        vm.startBroadcast(deployer);

        // Deploy implementation
        address implementation = address(new USDat(mToken, swapFacility));
        console.log("Implementation:  ", implementation);

        // Deploy proxy via CREATE3
        bytes memory initializerData =
            abi.encodeWithSelector(USDat.initialize.selector, yieldRecipient, admin, compliance, processor);

        address proxy = _deployCreate3TransparentProxy(
            implementation, admin, initializerData, _computeSalt(deployer, CONTRACT_NAME)
        );

        address proxyAdmin = Upgrades.getAdminAddress(proxy);

        vm.stopBroadcast();

        console.log("=======================================================");
        console.log("Deployment Complete");
        console.log("=======================================================");
        console.log("Proxy:           ", proxy);
        console.log("Proxy Admin:     ", proxyAdmin);
        console.log("=======================================================");
    }

    /**
     * @notice Computes the predicted proxy address for a given deployer.
     * @param  deployer The deployer address.
     * @return The predicted proxy address.
     */
    function predictAddress(address deployer) public view returns (address) {
        return _getCreate3Address(deployer, _computeSalt(deployer, CONTRACT_NAME));
    }

    /**
     * @notice Checks if PREDICTED_ADDRESS env var is set.
     * @return True if PREDICTED_ADDRESS is set, false otherwise.
     */
    function _shouldVerifyPredictedAddress() internal view returns (bool) {
        return vm.envOr("PREDICTED_ADDRESS", address(0)) != address(0);
    }

    /**
     * @notice Verifies predicted address against computed CREATE3 address.
     * @param  deployer The deployer address.
     */
    function _verifyPredictedAddress(address deployer) internal view {
        address predictedAddress = vm.envAddress("PREDICTED_ADDRESS");
        address computedAddress = predictAddress(deployer);

        console.log("Predicted Address:", predictedAddress);
        console.log("Computed Address: ", computedAddress);

        require(
            computedAddress == predictedAddress,
            string.concat(
                "Address mismatch! Predicted: ",
                vm.toString(predictedAddress),
                ", Computed: ",
                vm.toString(computedAddress)
            )
        );

        console.log("Address verification passed!");
    }

    /**
     * @notice Deploys a TransparentUpgradeableProxy via CREATE3.
     * @param  implementation  The implementation contract address.
     * @param  initialOwner    The initial owner of the proxy admin.
     * @param  initializerData The initializer calldata.
     * @param  salt            The CREATE3 salt.
     * @return The deployed proxy address.
     */
    function _deployCreate3TransparentProxy(
        address implementation,
        address initialOwner,
        bytes memory initializerData,
        bytes32 salt
    ) internal returns (address) {
        return ICreateXLike(CREATE_X_FACTORY)
            .deployCreate3(
                salt,
                abi.encodePacked(
                    type(TransparentUpgradeableProxy).creationCode,
                    abi.encode(implementation, initialOwner, initializerData)
                )
            );
    }

    /**
     * @notice Computes the CREATE3 salt for a given deployer and contract name.
     * @param  deployer     The deployer address.
     * @param  contractName The contract name.
     * @return The computed salt.
     */
    function _computeSalt(address deployer, string memory contractName) internal pure returns (bytes32) {
        return bytes32(
            abi.encodePacked(
                bytes20(deployer),
                bytes1(0), // disable cross-chain redeploy protection
                bytes11(keccak256(bytes(contractName)))
            )
        );
    }

    /**
     * @notice Computes the guarded salt for CREATE3 address computation.
     * @param  deployer The deployer address.
     * @param  salt     The base salt.
     * @return The guarded salt.
     */
    function _computeGuardedSalt(address deployer, bytes32 salt) internal pure returns (bytes32) {
        return _efficientHash(bytes32(uint256(uint160(deployer))), salt);
    }

    /**
     * @notice Efficiently hashes two bytes32 values.
     * @param  a First value.
     * @param  b Second value.
     * @return hash The keccak256 hash.
     */
    function _efficientHash(bytes32 a, bytes32 b) internal pure returns (bytes32 hash) {
        assembly ("memory-safe") {
            mstore(0x00, a)
            mstore(0x20, b)
            hash := keccak256(0x00, 0x40)
        }
    }

    /**
     * @notice Computes the CREATE3 address for a given deployer and salt.
     * @param  deployer The deployer address.
     * @param  salt     The base salt.
     * @return The predicted address.
     */
    function _getCreate3Address(address deployer, bytes32 salt) internal view returns (address) {
        return ICreateXLike(CREATE_X_FACTORY).computeCreate3Address(_computeGuardedSalt(deployer, salt));
    }
}
