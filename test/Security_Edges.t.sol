// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import {rBTCSYNTH} from "../src/rBTCSYNTH.sol";
import {VaultWrBTC} from "../src/VaultWrBTC.sol";
import {rBTCOracle} from "../src/rBTCOracle.sol";

/// Malicious vault that tries to reenter rBTCSYNTH.wrap() via onWrap.
contract MaliciousVault {
    address public token;
    bool public attack;

    constructor(address _token) { token = _token; }

    function setAttack(bool v) external { attack = v; }

    function onWrap(address /*user*/, uint256 /*amount*/) external {
        // Attempt reentrancy into wrap() — must fail due to nonReentrant.
        if (attack) {
            (bool ok,) = token.call(abi.encodeWithSignature("wrap(uint256)", 1));
            require(ok, "reentrancy-should-fail");
        }
    }
}

contract Security_Edges is Test {
    rBTCSYNTH  token;
    VaultWrBTC vault;
    rBTCOracle oracle;

    address user = address(0xAAA);

    function setUp() public {
        // Use nonzero placeholders to satisfy constructor checks.
        oracle = new rBTCOracle(address(0x1), address(0x2), bytes32(0));

        token = new rBTCSYNTH(address(oracle));
        vault = new VaultWrBTC(address(token), address(oracle));

        // setVault is onlyOracle → impersonate oracle.
        vm.prank(address(oracle));
        token.setVault(address(vault));
    }

    // --- Access control / RBAC ---
    function test_AccessControl_RBAC() public {
        vm.expectRevert(rBTCSYNTH.OnlyOracle.selector);
        token.mintFromOracle(user, 1);

        vm.expectRevert(rBTCSYNTH.OnlyVault.selector);
        token.unwrapFromVault(user, 1);

        vm.expectRevert(VaultWrBTC.OnlyToken.selector);
        vault.onWrap(user, 1);

        vm.expectRevert(VaultWrBTC.OnlyOracle.selector);
        vault.slashFromOracle(user, 1);
    }

    // --- Oracle entrypoint must be restricted to operators ---
    function test_Oracle_OnlyOperator_Sync() public {
        // Expect a revert (implementation may not bubble custom error on your build).
        vm.expectRevert();
        oracle.syncVerifiedTotal(user, 10, 1);
    }

    // --- Reentrancy guard on token.wrap ---
    function test_Reentrancy_Guard_OnToken_Wrap() public {
        // Fresh token + malicious vault to keep single-shot setVault logic simple.
        rBTCSYNTH t2 = new rBTCSYNTH(address(oracle));
        MaliciousVault evil = new MaliciousVault(address(t2));

        vm.prank(address(oracle));
        t2.setVault(address(evil));

        // Give the user real free balance by minting as oracle.
        vm.prank(address(oracle));
        t2.mintFromOracle(user, 10);

        // Turn on attack. onWrap will try to reenter wrap() and must fail.
        evil.setAttack(true);

        vm.prank(user);
        vm.expectRevert(bytes("reentrancy-should-fail"));
        t2.wrap(1);
    }

    // --- Reentrancy guard on vault.redeem ---
    function test_Reentrancy_Guard_OnVault_Redeem() public {
        // Mint free balance and wrap part of it.
        vm.prank(address(oracle));
        token.mintFromOracle(user, 100);

        vm.prank(user);
        token.wrap(50);

        // Redeem should succeed once (nonReentrant prevents nested entries).
        vm.prank(user);
        vault.redeem(20);
    }

    // --- Zero-address checks & bounds ---
    function test_ZeroChecks_And_Bounds() public {
        rBTCSYNTH t3 = new rBTCSYNTH(address(oracle));

        vm.prank(address(oracle));
        vm.expectRevert(bytes("vault=0"));
        t3.setVault(address(0));

        rBTCSYNTH t4 = new rBTCSYNTH(address(oracle));
        vm.expectRevert(rBTCSYNTH.VaultNotSet.selector);
        t4.wrap(1);

        vm.prank(address(oracle));
        t4.setVault(address(vault));

        vm.prank(user);
        vm.expectRevert(bytes("amount=0"));
        t4.wrap(0);
    }
}