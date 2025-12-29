// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.4.0
pragma solidity ^0.8.27;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20BurnableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract USDat is
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    ReentrancyGuard,
    AccessControlUpgradeable,
    ERC20PermitUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant PROCESSOR_ROLE = keccak256("PROCESSOR_ROLE");
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");

    /// @custom:storage-location erc7201:saturn.usdat.storage
    struct USDatStorage {
        mapping(address => bool) blacklisted;
    }

    // keccak256(abi.encode(uint256(keccak256("saturn.usdat.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant USDAT_STORAGE_LOCATION =
        0xd319317dee4509e78244ea42ada3c23f49b19eec2b552d2c52af685634fde100;

    function _getUSDatStorage() private pure returns (USDatStorage storage $) {
        assembly {
            $.slot := USDAT_STORAGE_LOCATION
        }
    }

    event Blacklisted(address indexed account);
    event UnBlacklisted(address indexed account);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address defaultAdmin,
        address processor,
        address compliance
    ) public initializer {
        __ERC20_init("USDat", "USDat");
        __ERC20Burnable_init();
        __AccessControl_init();
        __ERC20Permit_init("USDat");

        // Manages Upgrades
        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        // Manages minting new tokens
        _grantRole(PROCESSOR_ROLE, processor);
        // Manages compliance (blacklist)
        _grantRole(COMPLIANCE_ROLE, compliance);
    }

    function _requireNotBlacklisted(address account) internal view {
        USDatStorage storage $ = _getUSDatStorage();
        require(!$.blacklisted[account], "Recipient is blacklisted");
    }

    function mint(address to, uint256 amount) public onlyRole(PROCESSOR_ROLE) {
        _requireNotBlacklisted(to);
        _mint(to, amount);
    }

    function rescueTokens(
        address token,
        uint256 amount,
        address to
    ) external nonReentrant onlyRole(COMPLIANCE_ROLE) {
        IERC20(token).safeTransfer(to, amount);
    }

    function transfer(
        address to,
        uint256 amount
    ) public override returns (bool) {
        _requireNotBlacklisted(to);
        return super.transfer(to, amount);
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override returns (bool) {
        _requireNotBlacklisted(to);
        return super.transferFrom(from, to, amount);
    }

    function burnBlacklistedTokens(
        address account
    ) public onlyRole(COMPLIANCE_ROLE) {
        USDatStorage storage $ = _getUSDatStorage();
        require($.blacklisted[account], "Account is not blacklisted");
        uint256 amount = balanceOf(account);
        require(amount > 0, "Account has no balance");
        _burn(account, amount);
    }

    function addToBlacklist(
        address account
    ) external onlyRole(COMPLIANCE_ROLE) {
        USDatStorage storage $ = _getUSDatStorage();
        if ($.blacklisted[account]) revert("Already blacklisted");
        $.blacklisted[account] = true;
        emit Blacklisted(account);
    }

    function removeFromBlacklist(
        address account
    ) external onlyRole(COMPLIANCE_ROLE) {
        USDatStorage storage $ = _getUSDatStorage();
        if (!$.blacklisted[account]) revert("Not blacklisted");
        $.blacklisted[account] = false;
        emit UnBlacklisted(account);
    }

    function isBlacklisted(address account) external view returns (bool) {
        USDatStorage storage $ = _getUSDatStorage();
        return $.blacklisted[account];
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
