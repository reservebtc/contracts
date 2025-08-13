// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";

import {rBTCSYNTH} from "../src/rBTCSYNTH.sol";
import {VaultWrBTC} from "../src/VaultWrBTC.sol";
import {rBTCOracle} from "../src/rBTCOracle.sol";

/// @notice Malicious token used to simulate reentrancy during Vault.redeem().
/// It is set as the vault's rBTC token (so it passes onlyToken).
contract MaliciousTokenForRedeem {
    VaultWrBTC public vault;
    bool public attack;

    // Introspection flags for assertions
    bool public attempted;
    bool public nestedOk;

    function setVault(address v) external { vault = VaultWrBTC(v); }
    function setAttack(bool v) external { attack = v; }

    /// @notice Mint wrBTC via vault.onWrap() as the trusted token.
    function mintViaOnWrap(address user, uint256 amount) external {
        vault.onWrap(user, amount); // passes onlyToken because vault.rbtc == address(this)
    }

    /// @notice Called by the vault during redeem(); attempts to reenter redeem().
    function unwrapFromVault(address /*to*/, uint256 /*amount*/) external {
        if (attack) {
            attempted = true;
            (bool ok,) = address(vault).call(abi.encodeWithSignature("redeem(uint256)", 1));
            nestedOk = ok;                // must be false due to nonReentrant
            require(!ok, "reentrancy unexpectedly succeeded");
        }
    }
}

contract VaultWrBTC_Edges is Test {
    rBTCSYNTH  token;
    VaultWrBTC vault;
    rBTCOracle oracle;

    address user = address(0xAAA);

    function setUp() public {
        // Oracle with dummy links to satisfy constructor checks
        oracle = new rBTCOracle(address(0x1), address(0x2), bytes32(0));

        // Real token/vault pair for standard edge cases
        token = new rBTCSYNTH(address(oracle));
        vault = new VaultWrBTC(address(token), address(oracle));
        vm.prank(address(oracle));
        token.setVault(address(vault));
    }

    // ------------------------
    // Zero-amount wrap/redeem
    // ------------------------

    function test_Wrap_ZeroAmount_Reverts_or_NoOp() public {
        // Snapshot balances
        uint256 free0   = token.freeBalanceOf(user);
        uint256 esc0    = token.escrowOf(user);
        uint256 wr0     = vault.balanceOf(user);
        uint256 total0  = vault.totalSupply();

        // If repo already has `require(amount>0)`, wrap(0) will revert.
        // If not, it should be a pure no-op (no state change).
        vm.prank(user);
        try token.wrap(0) {
            // No revert: assert no-op
            assertEq(token.freeBalanceOf(user), free0,  "free changed on wrap(0)");
            assertEq(token.escrowOf(user),      esc0,   "escrow changed on wrap(0)");
            assertEq(vault.balanceOf(user),     wr0,    "wrBTC changed on wrap(0)");
            assertEq(vault.totalSupply(),       total0, "totalSupply changed on wrap(0)");
        } catch {
            // Reverted (e.g., with "amount=0"): also OK
        }
    }

    function test_Redeem_ZeroAmount_NoStateChange() public {
        // Prepare wrBTC
        vm.prank(address(oracle));
        token.mintFromOracle(user, 100);
        vm.prank(user);
        token.wrap(50);

        uint256 wr0    = vault.balanceOf(user);
        uint256 total0 = vault.totalSupply();

        vm.prank(user);
        vault.redeem(0); // should not revert and should not change balances

        assertEq(vault.balanceOf(user), wr0,    "wrBTC changed on redeem(0)");
        assertEq(vault.totalSupply(),   total0, "totalSupply changed on redeem(0)");
    }

    // --------------------------
    // Redeem without any balance
    // --------------------------

    function test_Redeem_WithoutBalance_Reverts() public {
        vm.prank(user);
        vm.expectRevert(VaultWrBTC.InsufficientBalance.selector);
        vault.redeem(1);
    }

    // -----------------------------
    // Reentrancy on redeem is blocked
    // -----------------------------

    function test_Redeem_Reentrancy_Blocked() public {
        // 1) Deploy the malicious token first (no vault linked yet).
        MaliciousTokenForRedeem evil = new MaliciousTokenForRedeem();

        // 2) Deploy a fresh vault whose rbtc is the malicious token.
        VaultWrBTC v2 = new VaultWrBTC(address(evil), address(oracle));

        // 3) Link the vault address inside the malicious token so it can try reentrancy.
        evil.setVault(address(v2));

        // 4) Mint wrBTC to user through onWrap() called by the malicious token.
        evil.mintViaOnWrap(user, 10);
        assertEq(v2.balanceOf(user), 10);

        // 5) Enable the attack and attempt to redeem.
        //    nonReentrant must block the nested call, but the outer redeem succeeds.
        evil.setAttack(true);

        uint256 wrBefore    = v2.balanceOf(user);
        uint256 totalBefore = v2.totalSupply();

        vm.prank(user);
        v2.redeem(1);

        // Outer redeem succeeded and burned exactly 1 wrBTC
        assertEq(v2.balanceOf(user), wrBefore - 1, "outer redeem did not burn");
        assertEq(v2.totalSupply(),   totalBefore - 1, "totalSupply not reduced");

        // Nested attempt happened and was blocked
        assertTrue(evil.attempted(), "no nested attempt recorded");
        assertFalse(evil.nestedOk(), "nested redeem unexpectedly succeeded");
    }

    // ------
    //  RBAC
    // ------

    function test_RBAC_OnWrap_OnlyToken() public {
        vm.expectRevert(VaultWrBTC.OnlyToken.selector);
        vault.onWrap(user, 1);
    }

    function test_RBAC_SlashFromOracle_OnlyOracle() public {
        vm.expectRevert(VaultWrBTC.OnlyOracle.selector);
        vault.slashFromOracle(user, 1);

        // Prepare balance and wrap
        vm.prank(address(oracle));
        token.mintFromOracle(user, 100);
        vm.prank(user);
        token.wrap(40);
        assertEq(vault.balanceOf(user), 40);

        vm.prank(address(oracle));
        vault.slashFromOracle(user, 10);
        assertEq(vault.balanceOf(user), 30, "slash did not burn wrBTC");
    }
}