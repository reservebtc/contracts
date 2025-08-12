// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import {rBTCSYNTH} from "../src/rBTCSYNTH.sol";
import {VaultWrBTC} from "../src/VaultWrBTC.sol";

contract VaultWrBTC_Unit is Test {
    rBTCSYNTH internal token;
    VaultWrBTC internal vault;

    address internal oracle = address(this);
    address internal alice = address(0xA11CE);
    address internal bob   = address(0xB0B);

    function setUp() public {
        token = new rBTCSYNTH(oracle);
        vault = new VaultWrBTC(address(token), oracle);
        token.setVault(address(vault));
    }

    function test_OnWrap_MintsWrBTC() public {
        token.mintFromOracle(alice, 1_000);
        vm.prank(alice);
        token.wrap(750);
        assertEq(vault.balanceOf(alice), 750);
        assertEq(vault.totalSupply(), 750);
    }

    function test_Redeem_BurnsWrAndUnwraps() public {
        token.mintFromOracle(alice, 1_000);
        vm.prank(alice);
        token.wrap(400);

        vm.prank(alice);
        vault.redeem(250);

        assertEq(vault.balanceOf(alice), 150);
        assertEq(vault.totalSupply(), 150);
        assertEq(token.escrowOf(alice), 150);
        assertEq(token.freeBalanceOf(alice), 600);
    }

    function test_SlashFromOracle() public {
        token.mintFromOracle(alice, 500);
        vm.prank(alice);
        token.wrap(500);
        // slash 180
        vault.slashFromOracle(alice, 180);
        assertEq(vault.balanceOf(alice), 320);
        assertEq(vault.totalSupply(), 320);
        // token escrow will be debited by oracle in separate call (tested in oracle tests)
    }

    function test_Transfers_And_Allowance() public {
        token.mintFromOracle(alice, 1_000);
        vm.prank(alice);
        token.wrap(300);

        vm.prank(alice);
        vault.transfer(bob, 120);
        assertEq(vault.balanceOf(bob), 120);

        vm.prank(alice);
        vault.approve(bob, 50);

        vm.prank(bob);
        vault.transferFrom(alice, bob, 50);

        assertEq(vault.balanceOf(alice), 130);
        assertEq(vault.balanceOf(bob), 170);
    }
}
