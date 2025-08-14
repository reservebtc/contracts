// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import {VaultWrBTC} from "../src/VaultWrBTC.sol";

// Minimal event interface to assert logs
interface IEvents {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

// Dumb placeholders to satisfy non-zero constructor arguments.
// They do nothing; we only need their non-zero addresses.
contract DummyA {}
contract DummyB {}

contract VaultWrBTC_ERC20_Unit is Test, IEvents {
    VaultWrBTC internal vault;
    address internal alice = address(0xA11CE);
    address internal bob   = address(0xB0B);

    function setUp() public {
        // Deploy non-zero dummies to pass into the Vault constructor
        DummyA a = new DummyA();
        DummyB b = new DummyB();

        // If your VaultWrBTC constructor expects (address X, address Y),
        // passing any non-zero addresses will satisfy zero-address checks.
        vault = new VaultWrBTC(address(a), address(b));

        // Seed Alice with 1000 tokens. The last 'true' emits a Transfer(0x0, alice).
        deal(address(vault), alice, 1000, true);
    }

    function test_Approve_and_Allowance_emit_Approval() public {
        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit Approval(alice, bob, 500);
        bool ok = vault.approve(bob, 500);
        assertTrue(ok, "approve should return true");
        assertEq(vault.allowance(alice, bob), 500, "allowance must be set");
    }

    function test_Transfer_emits_Transfer_and_moves_balances() public {
        vm.startPrank(alice);
        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, bob, 300);
        bool ok = vault.transfer(bob, 300);
        vm.stopPrank();

        assertTrue(ok, "transfer should return true");
        assertEq(vault.balanceOf(alice), 700, "alice decreased");
        assertEq(vault.balanceOf(bob),   300, "bob increased");
    }

    function test_Transfer_zero_allowed_and_no_balance_change() public {
        uint256 a0 = vault.balanceOf(alice);
        uint256 b0 = vault.balanceOf(bob);

        vm.prank(alice);
        (bool ok, ) = address(vault).call(
            abi.encodeWithSignature("transfer(address,uint256)", bob, 0)
        );
        assertTrue(ok, "transfer(0) should not revert");
        assertEq(vault.balanceOf(alice), a0);
        assertEq(vault.balanceOf(bob),   b0);
    }

    function test_transferFrom_consumes_allowance_and_emits() public {
        vm.prank(alice);
        vault.approve(bob, 400);

        vm.prank(bob);
        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, bob, 250);
        bool ok = vault.transferFrom(alice, bob, 250);
        assertTrue(ok, "transferFrom should return true");

        assertEq(vault.balanceOf(alice), 750);
        assertEq(vault.balanceOf(bob),   250);
        assertEq(vault.allowance(alice, bob), 150);
    }

    function test_TransferFrom_over_allowance_reverts() public {
        vm.prank(alice);
        vault.approve(bob, 100);

        vm.prank(bob);
        vm.expectRevert();
        vault.transferFrom(alice, bob, 101);
    }

    function test_Transfer_over_balance_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.transfer(bob, 1001);
    }

    function test_Approve_overwrite_allows_reset() public {
        vm.startPrank(alice);
        vault.approve(bob, 123);
        assertEq(vault.allowance(alice, bob), 123);
        vault.approve(bob, 0);
        assertEq(vault.allowance(alice, bob), 0);
        vm.stopPrank();
    }
}