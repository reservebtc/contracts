// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import {rBTCSYNTH} from "../src/rBTCSYNTH.sol";
import {VaultWrBTC} from "../src/VaultWrBTC.sol";

contract RBTCSynth_Unit is Test {
    rBTCSYNTH internal token;
    VaultWrBTC internal vault;

    address internal oracle = address(this); // we act as oracle in unit tests
    address internal alice = address(0xA11CE);
    address internal bob   = address(0xB0B);

    function setUp() public {
        token = new rBTCSYNTH(oracle);
        vault = new VaultWrBTC(address(token), oracle);
        // set vault once via oracle
        token.setVault(address(vault));
        token.freezeVaultAddress();
    }

    // --- Helpers ---
    function _mintTo(address to, uint256 amount) internal {
        token.mintFromOracle(to, amount);
    }

    // --- Tests ---
    function test_Soulbound_NoTransfers() public {
        _mintTo(alice, 100);
        vm.expectRevert(rBTCSYNTH.TransfersDisabled.selector);
        token.transfer(bob, 50);
        vm.expectRevert(rBTCSYNTH.TransfersDisabled.selector);
        token.approve(bob, 50);
        vm.expectRevert(rBTCSYNTH.TransfersDisabled.selector);
        token.transferFrom(alice, bob, 50);
        assertEq(token.freeBalanceOf(alice), 100);
        assertEq(token.freeBalanceOf(bob), 0);
    }

    function test_Wrap_Unwrap_HappyPath() public {
        _mintTo(alice, 1_000);
        vm.prank(alice);
        token.wrap(600);
        // free -> down, escrow -> up, vault mints wrBTC
        assertEq(token.freeBalanceOf(alice), 400);
        assertEq(token.escrowOf(alice), 600);
        assertEq(vault.balanceOf(alice), 600);
        assertEq(vault.totalSupply(), 600);

        // redeem 200 wrBTC
        vm.startPrank(alice);
        vault.redeem(200);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 400);
        assertEq(vault.totalSupply(), 400);
        assertEq(token.escrowOf(alice), 400);
        assertEq(token.freeBalanceOf(alice), 600);
    }

    function test_BurnFromOracle_FromFreeOnly() public {
        _mintTo(alice, 500);
        vm.prank(alice);
        token.wrap(300); // free=200, escrow=300
        // burn 150 from free
        token.burnFromOracle(alice, 150);
        assertEq(token.freeBalanceOf(alice), 50);
        assertEq(token.escrowOf(alice), 300);
        // cannot burn more than free
        vm.expectRevert(rBTCSYNTH.InsufficientFree.selector);
        token.burnFromOracle(alice, 100);
    }

    function test_DebitEscrowFromOracle_RequireEnough() public {
        _mintTo(alice, 500);
        vm.prank(alice);
        token.wrap(400); // escrow=400
        token.debitEscrowFromOracle(alice, 250);
        assertEq(token.escrowOf(alice), 150);
        vm.expectRevert(rBTCSYNTH.InsufficientEscrow.selector);
        token.debitEscrowFromOracle(alice, 200);
    }

    function test_Wrap_RevertIfVaultNotSet() public {
        // deploy fresh token with no vault set
        rBTCSYNTH t = new rBTCSYNTH(oracle);
        t.mintFromOracle(alice, 10);
        vm.prank(alice);
        vm.expectRevert(rBTCSYNTH.VaultNotSet.selector);
        t.wrap(5);
    }
}
