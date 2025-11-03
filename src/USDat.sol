// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.4.0
pragma solidity ^0.8.27;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract USDat is ERC20, ERC20Burnable, ReentrancyGuard, AccessControl, ERC20Permit {
    using SafeERC20 for IERC20;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BLACKLIST_MANAGER_ROLE = keccak256("BLACKLIST_MANAGER_ROLE");

    mapping(address => bool) private _blacklisted;
    event Blacklisted(address indexed account);
    event UnBlacklisted(address indexed account);

    constructor(address defaultAdmin, address minter, address blacklistManager) ERC20("USDat", "USDat") ERC20Permit("USDat") {
        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(MINTER_ROLE, minter);
        _grantRole(BLACKLIST_MANAGER_ROLE, blacklistManager);
    }

    function _requireNotBlacklisted(address account) internal view {
        require(!_blacklisted[account], "Recipient is blacklisted");
    }

    function mint(address to, uint256 amount) public onlyRole(MINTER_ROLE) {
        _requireNotBlacklisted(to);
        _mint(to, amount);
    }

     function rescueTokens(address token, uint256 amount, address to)
        external
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        IERC20(token).safeTransfer(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _requireNotBlacklisted(to);
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _requireNotBlacklisted(to);
        return super.transferFrom(from, to, amount);
    }

    function burnBlacklistedTokens(address account) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireNotBlacklisted(account);
        uint256 amount = balanceOf(account);
        require(amount > 0, "Account has no balance");
        _burn(account, amount);
    }

    function addToBlacklist(address account) external onlyRole(BLACKLIST_MANAGER_ROLE) {
        if (_blacklisted[account]) revert("Already blacklisted");
        _blacklisted[account] = true;
        emit Blacklisted(account);
    }

    function removeFromBlacklist(address account) external onlyRole(BLACKLIST_MANAGER_ROLE) {
        if (!_blacklisted[account]) revert("Not blacklisted");
        _blacklisted[account] = false;
        emit UnBlacklisted(account);
    }

    function isBlacklisted(address account) external view returns (bool) {
        return _blacklisted[account];
    }
    
}
