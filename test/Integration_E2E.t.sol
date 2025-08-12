// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import {rBTCSYNTH} from "../src/rBTCSYNTH.sol";
import {VaultWrBTC} from "../src/VaultWrBTC.sol";

/**
 * Integration-like test wiring real rBTCSYNTH + VaultWrBTC.
 * Oracle is an EOA (address(this)), matching the current production pattern.
 * We exercise wrap → redeem flows end-to-end.
 */
contract Integration_E2E is Test {
    rBTCSYNTH internal token;
    VaultWrBTC internal vault;

    address internal oracleEOA = address(this);
    address internal alice = address(0xA11CE);

    function setUp() public {
        token = new rBTCSYNTH(oracleEOA);
        vault = new VaultWrBTC(address(token), oracleEOA);
        // set vault from the oracle EOA
        token.setVault(address(vault));
    }

    function test_Flow_WrapRedeem_E2E() public {
        // Mint to Alice from the oracle EOA
        token.mintFromOracle(alice, 10_000);

        // Alice wraps 6_000 into wrBTC
        vm.prank(alice);
        token.wrap(6_000);
        assertEq(vault.balanceOf(alice), 6_000);
        assertEq(token.escrowOf(alice), 6_000);
        assertEq(token.freeBalanceOf(alice), 4_000);

        // Alice redeems 2_500 wrBTC back to rBTC-SYNTH
        vm.prank(alice);
        vault.redeem(2_500);

        assertEq(vault.balanceOf(alice), 3_500);
        assertEq(token.escrowOf(alice), 3_500);
        assertEq(token.freeBalanceOf(alice), 6_500);
    }
}