// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {UScc} from "../src/UScc.sol";
import {IUScc} from "../src/IUScc.sol";

contract USccTest is Test {
    UScc public token;
    address public owner;
    address public minter;
    address public user1;
    address public user2;

    function setUp() public {
        owner = makeAddr("owner");
        minter = makeAddr("minter");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        vm.prank(owner);
        token = new UScc(owner);
    }

    /* ============ Constructor Tests ============ */

    function test_Constructor() public view {
        assertEq(token.name(), "UScc");
        assertEq(token.symbol(), "UScc");
        assertEq(token.decimals(), 18);
        assertEq(token.owner(), owner);
        assertEq(token.minter(), address(0));
    }

    /* ============ Minter Tests ============ */

    function test_SetMinter() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit IUScc.MinterUpdated(minter, address(0));
        token.setMinter(minter);

        assertEq(token.minter(), minter);
    }

    function test_RevertWhen_NonOwnerSetsMinter() public {
        vm.prank(user1);
        vm.expectRevert();
        token.setMinter(minter);
    }

    function test_SetMinterToZeroAddress() public {
        // First set a minter
        vm.prank(owner);
        token.setMinter(minter);

        // Then set to zero address
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit IUScc.MinterUpdated(address(0), minter);
        token.setMinter(address(0));

        assertEq(token.minter(), address(0));
    }

    /* ============ Mint Tests ============ */

    function test_Mint() public {
        vm.prank(owner);
        token.setMinter(minter);

        vm.prank(minter);
        token.mint(user1, 1000e18);

        assertEq(token.balanceOf(user1), 1000e18);
        assertEq(token.totalSupply(), 1000e18);
    }

    function test_RevertWhen_NonMinterMints() public {
        vm.prank(owner);
        token.setMinter(minter);

        vm.prank(user1);
        vm.expectRevert(IUScc.OnlyMinter.selector);
        token.mint(user1, 1000e18);
    }

    function test_RevertWhen_MinterNotSet() public {
        vm.prank(user1);
        vm.expectRevert(IUScc.OnlyMinter.selector);
        token.mint(user1, 1000e18);
    }

    function testFuzz_Mint(address to, uint256 amount) public {
        vm.assume(to != address(0));
        vm.assume(amount < type(uint256).max);

        vm.prank(owner);
        token.setMinter(minter);

        vm.prank(minter);
        token.mint(to, amount);

        assertEq(token.balanceOf(to), amount);
        assertEq(token.totalSupply(), amount);
    }

    /* ============ Burn Tests ============ */

    function test_Burn() public {
        vm.prank(owner);
        token.setMinter(minter);

        vm.prank(minter);
        token.mint(user1, 1000e18);

        vm.prank(user1);
        token.burn(500e18);

        assertEq(token.balanceOf(user1), 500e18);
        assertEq(token.totalSupply(), 500e18);
    }

    function test_BurnFrom() public {
        vm.prank(owner);
        token.setMinter(minter);

        vm.prank(minter);
        token.mint(user1, 1000e18);

        vm.prank(user1);
        token.approve(user2, 500e18);

        vm.prank(user2);
        token.burnFrom(user1, 500e18);

        assertEq(token.balanceOf(user1), 500e18);
        assertEq(token.totalSupply(), 500e18);
    }

    /* ============ Ownership Tests ============ */

    function test_RevertWhen_RenounceOwnership() public {
        vm.prank(owner);
        vm.expectRevert(IUScc.CantRenounceOwnership.selector);
        token.renounceOwnership();

        assertEq(token.owner(), owner);
    }

    function test_TransferOwnership() public {
        vm.prank(owner);
        token.transferOwnership(user1);

        assertEq(token.pendingOwner(), user1);
        assertEq(token.owner(), owner);

        vm.prank(user1);
        token.acceptOwnership();

        assertEq(token.owner(), user1);
        assertEq(token.pendingOwner(), address(0));
    }

    function test_RevertWhen_NonOwnerTransfersOwnership() public {
        vm.prank(user1);
        vm.expectRevert();
        token.transferOwnership(user2);
    }

    /* ============ ERC20 Tests ============ */

    function test_Transfer() public {
        vm.prank(owner);
        token.setMinter(minter);

        vm.prank(minter);
        token.mint(user1, 1000e18);

        vm.prank(user1);
        token.transfer(user2, 500e18);

        assertEq(token.balanceOf(user1), 500e18);
        assertEq(token.balanceOf(user2), 500e18);
    }

    function test_Approve() public {
        vm.prank(user1);
        token.approve(user2, 1000e18);

        assertEq(token.allowance(user1, user2), 1000e18);
    }

    function test_TransferFrom() public {
        vm.prank(owner);
        token.setMinter(minter);

        vm.prank(minter);
        token.mint(user1, 1000e18);

        vm.prank(user1);
        token.approve(user2, 500e18);

        vm.prank(user2);
        token.transferFrom(user1, user2, 500e18);

        assertEq(token.balanceOf(user1), 500e18);
        assertEq(token.balanceOf(user2), 500e18);
    }

    /* ============ ERC20Permit Tests ============ */

    function test_Permit() public {
        uint256 privateKey = 0xA11CE;
        address alice = vm.addr(privateKey);

        vm.prank(owner);
        token.setMinter(minter);

        vm.prank(minter);
        token.mint(alice, 1000e18);

        uint256 deadline = block.timestamp + 1 days;
        uint256 nonce = token.nonces(alice);

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                alice,
                user1,
                500e18,
                nonce,
                deadline
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        token.permit(alice, user1, 500e18, deadline, v, r, s);

        assertEq(token.allowance(alice, user1), 500e18);
    }
}
