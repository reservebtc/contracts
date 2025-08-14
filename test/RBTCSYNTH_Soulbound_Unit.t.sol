// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import {rBTCSYNTH} from "../src/rBTCSYNTH.sol";

/* ---------------------------------------------------------------------- */
/*                                Mocks                                   */
/* ---------------------------------------------------------------------- */

interface IVaultLike {
    function onWrap(address user, uint256 amount) external;
}

/**
 * @dev Minimal Vault mock that accepts onWrap() and can call unwrapFromVault()
 *      on the token (so we simulate a real Vault caller).
 */
contract MockVault {
    rBTCSYNTH public immutable token;

    constructor(rBTCSYNTH _token) {
        token = _token;
    }

    // Called by token.wrap(); we keep it as a no-op to not interfere with balances.
    function onWrap(address /*user*/, uint256 /*amount*/) external {}

    // Helper to simulate a real Vault calling the token's unwrap entrypoint
    function callUnwrap(address user, uint256 amount) external {
        token.unwrapFromVault(user, amount);
    }
}

/* ---------------------------------------------------------------------- */
/*                               Unit tests                               */
/* ---------------------------------------------------------------------- */

contract RBTCSYNTH_Soulbound_Unit is Test {
    rBTCSYNTH internal t;
    MockVault internal v;

    // actors
    address internal oracle; // this contract
    address internal alice;
    address internal bob;

    function setUp() public {
        oracle = address(this);
        alice  = address(0xA11CE);
        bob    = address(0xB0B);

        // Deploy token with oracle = this test contract
        t = new rBTCSYNTH(oracle);

        // Deploy mock vault and wire it
        v = new MockVault(t);
        t.setVault(address(v));
    }

    /* ------------------------- Oracle-only hooks ------------------------- */

    function test_Oracle_mint_burn_debitEscrow_state_changes() public {
        // Mint to Alice
        t.mintFromOracle(alice, 1_000);
        assertEq(t.freeBalanceOf(alice), 1_000, "mint -> free");

        // Wrap 600 (invokes vault.onWrap via our MockVault)
        vm.prank(alice);
        t.wrap(600);
        assertEq(t.freeBalanceOf(alice), 400, "wrap dec free");
        assertEq(t.escrowOf(alice), 600, "wrap inc escrow");

        // Burn 300 from free
        t.burnFromOracle(alice, 300);
        assertEq(t.freeBalanceOf(alice), 100, "burn dec free");

        // Debit escrow 200
        t.debitEscrowFromOracle(alice, 200);
        assertEq(t.escrowOf(alice), 400, "debit dec escrow");
    }

    function test_Burn_more_than_free_reverts() public {
        t.mintFromOracle(alice, 100);
        vm.expectRevert(); // generic guard/underflow revert
        t.burnFromOracle(alice, 200);
    }

    function test_DebitEscrow_more_than_escrow_reverts() public {
        t.mintFromOracle(alice, 500);
        vm.prank(alice);
        t.wrap(300); // escrow = 300
        vm.expectRevert();
        t.debitEscrowFromOracle(alice, 400); // > escrow -> revert
    }

    /* ------------------------- Vault-only hook --------------------------- */

    function test_UnwrapFromVault_onlyVault_reverts_for_non_vault() public {
        // Prepare some escrow
        t.mintFromOracle(alice, 1_000);
        vm.prank(alice);
        t.wrap(700);

        // Non-vault caller must revert
        vm.expectRevert();
        t.unwrapFromVault(alice, 100);
    }

    function test_Unwrap_more_than_escrow_reverts() public {
        t.mintFromOracle(alice, 400);
        vm.prank(alice);
        t.wrap(300); // escrow = 300

        // Call as the real vault (MockVault) but exceed escrow -> revert
        vm.prank(address(v));
        vm.expectRevert();
        t.unwrapFromVault(alice, 400);
    }

    /* ----------------------------- Wrap path ----------------------------- */

    function test_Wrap_zero_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        t.wrap(0);
    }

    function test_Wrap_moves_balances() public {
        // Seed free balance
        t.mintFromOracle(alice, 1_000);

        vm.prank(alice);
        t.wrap(600);

        assertEq(t.freeBalanceOf(alice), 400, "free after wrap");
        assertEq(t.escrowOf(alice), 600, "escrow after wrap");
    }

    /* --------------------------- Soulbound API --------------------------- */

    function test_Soulbound_transfer_blocks() public {
        t.mintFromOracle(alice, 10);
        vm.expectRevert();
        t.transfer(bob, 1);
    }

    function test_Soulbound_transferFrom_blocks() public {
        t.mintFromOracle(alice, 10);
        vm.expectRevert();
        t.transferFrom(alice, bob, 1);
    }

    function test_Soulbound_approve_blocks_and_allowance_zero() public {
        // approve is blocked; we assert allowance remains zero
        vm.expectRevert();
        t.approve(bob, 5);
        assertEq(t.allowance(alice, bob), 0, "allowance must stay zero");
    }

    /* ---------------------------- Vault wiring --------------------------- */

    function test_SetVault_only_once() public {
        // setVault already called in setUp()
        vm.expectRevert();
        t.setVault(address(0x1111111111111111111111111111111111111111));
    }
}