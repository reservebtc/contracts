// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";

// ==== Repo contracts ====
import {rBTCSYNTH} from "../src/rBTCSYNTH.sol";
import {VaultWrBTC} from "../src/VaultWrBTC.sol";
import {rBTCOracle} from "../src/rBTCOracle.sol";

// ==== Interfaces (local minimal copies) ====
interface IRBTCToken {
    function freeBalanceOf(address u) external view returns (uint256);
    function escrowOf(address u) external view returns (uint256);
    function totalBackedOf(address u) external view returns (uint256);
    function mintFromOracle(address to, uint256 amount) external;
    function burnFromOracle(address from, uint256 amount) external;
    function debitEscrowFromOracle(address user, uint256 amount) external;
}

// -------------------------------------------------------
// Malicious vault: tries to reenter rBTCSYNTH.wrap via onWrap()
// -------------------------------------------------------
contract ReentrantVault {
    rBTCSYNTH public immutable token;
    constructor(address _token) { token = rBTCSYNTH(_token); }

    function onWrap(address /*user*/, uint256 amount) external {
        // Attempt immediate reentry
        token.wrap(amount);
    }
}

// -------------------------------------------------------
// Malicious token: during unwrapFromVault it tries to reenter
// Vault.redeem(). We record whether reentry succeeded.
// -------------------------------------------------------
contract ReentrantToken {
    address public vault;
    bool public reenterSucceeded;

    function unwrapFromVault(address /*to*/, uint256 /*amount*/) external {
        // Try to reenter Vault.redeem while it's already executing.
        (bool ok,) = vault.call(abi.encodeWithSignature("redeem(uint256)", 1));
        // Record result; the test will assert that this is false.
        reenterSucceeded = ok;
    }

    // Helper to mint wrBTC via onWrap() as if called by the token itself.
    function callOnWrap(address _vault, address user, uint256 amount) external {
        vault = _vault;
        (bool ok,) = _vault.call(abi.encodeWithSignature("onWrap(address,uint256)", user, amount));
        require(ok, "onWrap failed");
    }
}

// -------------------------------------------------------
// Mock token WITHOUT OnlyOracle checks (for oracle sync test).
// Implements IRBTCToken semantics used by rBTCOracle.
// -------------------------------------------------------
contract MockSynNoAuth is IRBTCToken {
    mapping(address => uint256) internal _free;
    mapping(address => uint256) internal _esc;

    function freeBalanceOf(address u) external view returns (uint256) { return _free[u]; }
    function escrowOf(address u) external view returns (uint256) { return _esc[u]; }
    function totalBackedOf(address u) public view returns (uint256) { return _free[u] + _esc[u]; }

    function mintFromOracle(address to, uint256 amount) external { _free[to] += amount; }
    function burnFromOracle(address from, uint256 amount) external { _free[from] -= amount; }
    function debitEscrowFromOracle(address user, uint256 amount) external { _esc[user] -= amount; }

    // test helpers
    function wrapFor(address user, uint256 amount) external {
        require(_free[user] >= amount, "insufficient");
        _free[user] -= amount; _esc[user] += amount;
    }
}

contract Security_Edges is Test {
    address internal owner = address(this);
    address internal alice = address(0xA11CE);

    // ========== 1) Reentrancy guard on rBTCSYNTH.wrap ==========
    function test_Reentrancy_Guard_OnToken_Wrap() public {
        rBTCSYNTH t = new rBTCSYNTH(owner);
        ReentrantVault evil = new ReentrantVault(address(t));
        t.setVault(address(evil));
        t.freezeVaultAddress();

        t.mintFromOracle(alice, 10);

        vm.prank(alice);
        vm.expectRevert(bytes("ReentrancyGuard: reentrant"));
        t.wrap(5);
    }

    // ========== 2) Reentrancy guard on Vault.redeem ==========
    function test_Reentrancy_Guard_OnVault_Redeem() public {
        ReentrantToken evilT = new ReentrantToken();
        VaultWrBTC v = new VaultWrBTC(address(evilT), owner);

        // Mint wrBTC to Alice by calling onWrap from the token
        evilT.callOnWrap(address(v), alice, 3);
        assertEq(v.balanceOf(alice), 3);

        // Outer call SHOULD NOT revert; inner reentry attempt must fail.
        vm.prank(alice);
        v.redeem(1);

        // Confirm reentry attempt did not succeed (guard worked).
        assertFalse(evilT.reenterSucceeded(), "reentry unexpectedly succeeded");
    }

    // ========== 3) Access control: OnlyOracle/OnlyVault/OnlyToken ==========
    function test_AccessControl_RBAC() public {
        rBTCSYNTH t = new rBTCSYNTH(owner);
        VaultWrBTC v = new VaultWrBTC(address(t), owner);

        // Link vault
        t.setVault(address(v));
        t.freezeVaultAddress();

        // OnlyOracle: mint/burn/debit
        vm.prank(alice);
        vm.expectRevert(rBTCSYNTH.OnlyOracle.selector);
        t.mintFromOracle(alice, 1);

        // OnlyToken: onWrap
        vm.expectRevert(VaultWrBTC.OnlyToken.selector);
        v.onWrap(alice, 1);

        // OnlyVault: unwrapFromVault
        vm.expectRevert(rBTCSYNTH.OnlyVault.selector);
        t.unwrapFromVault(alice, 1);

        // OnlyOracle: slashFromOracle
        vm.prank(alice);
        vm.expectRevert(VaultWrBTC.OnlyOracle.selector);
        v.slashFromOracle(alice, 1);
    }

    // ========== 4) Zero-checks and bounds ==========
    function test_ZeroChecks_And_Bounds() public {
        rBTCSYNTH t = new rBTCSYNTH(owner);
        VaultWrBTC v = new VaultWrBTC(address(t), owner);

        // zero address check must trigger BEFORE any set
        vm.expectRevert(bytes("vault=0"));
        t.setVault(address(0));

        // then set and freeze properly
        t.setVault(address(v));
        t.freezeVaultAddress();

        // wrap amount 0
        t.mintFromOracle(alice, 5);
        vm.prank(alice);
        vm.expectRevert(bytes("amount=0"));
        t.wrap(0);

        // redeem more than balance
        vm.prank(alice);
        t.wrap(3);
        vm.prank(alice);
        vm.expectRevert(VaultWrBTC.InsufficientBalance.selector);
        v.redeem(10);

        // owner zero-check in oracle
        rBTCOracle o = new rBTCOracle(address(t), address(v), bytes32(0));
        vm.expectRevert(bytes("owner=0"));
        o.setOwner(address(0));
    }

    // ========== 5) Oracle: OnlyOperator gate with mock token ==========
    function test_Oracle_OnlyOperator_Sync() public {
        // Use mock without OnlyOracle to avoid cross-contract auth mismatch
        MockSynNoAuth t = new MockSynNoAuth();
        VaultWrBTC v = new VaultWrBTC(address(0xdead), owner); // not used by mock path
        rBTCOracle o = new rBTCOracle(address(t), address(v), bytes32(0));

        // Non-operator should revert
        vm.prank(alice);
        vm.expectRevert(rBTCOracle.OnlyOperator.selector);
        o.syncVerifiedTotal(alice, 100, 1);

        // Make Alice operator
        o.setOperator(alice, true);

        // Now allowed
        vm.prank(alice);
        o.syncVerifiedTotal(alice, 100, 2);
        assertEq(t.freeBalanceOf(alice), 100);
    }
}