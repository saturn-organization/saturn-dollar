// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.4.0
pragma solidity ^0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IUScc} from "src/IUScc.sol";

contract UScc is ERC20, ERC20Burnable, Ownable2Step, ERC20Permit, IUScc {
    address public minter;

    constructor(address initialOwner)
        ERC20("UScc", "UScc")
        Ownable(initialOwner)
        ERC20Permit("UScc")
    {}

    function renounceOwnership() public view override onlyOwner {
        revert CantRenounceOwnership();
    }

    function setMinter(address newMinter) external onlyOwner {
        emit MinterUpdated(newMinter, minter);
        minter = newMinter;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert OnlyMinter();
        _mint(to, amount);
    }
}