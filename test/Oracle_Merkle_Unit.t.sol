// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import {rBTCOracle} from "../src/rBTCOracle.sol";

// Minimal token/vault interfaces required by rBTCOracle
interface IRBTCToken {
    function freeBalanceOf(address) external view returns (uint256);
    function totalBackedOf(address) external view returns (uint256);

    function mintFromOracle(address to, uint256 amount) external;
    function burnFromOracle(address from, uint256 amount) external;
    function debitEscrowFromOracle(address user, uint256 amount) external;
}
interface IWrVault {
    function slashFromOracle(address user, uint256 amount) external;
}

// Observable token mock to track free/escrow/total changes
contract MockRBTCToken is IRBTCToken {
    mapping(address => uint256) public free;
    mapping(address => uint256) public escrow;
    mapping(address => uint256) public total;

    function freeBalanceOf(address u) external view returns (uint256) { return free[u]; }
    function totalBackedOf(address u) external view returns (uint256) { return total[u]; }

    function mintFromOracle(address to, uint256 amount) external {
        free[to]  += amount;
        total[to] += amount;
    }

    function burnFromOracle(address from, uint256 amount) external {
        require(free[from] >= amount, "burn>free");
        free[from]  -= amount;
        total[from] -= amount;
    }

    function debitEscrowFromOracle(address user, uint256 amount) external {
        require(escrow[user] >= amount, "debit>escrow");
        escrow[user] -= amount;
        total[user]  -= amount;
    }

    // Helper to seed balances for tests
    function _seed(address u, uint256 freeAmt, uint256 escrowAmt) external {
        free[u]   = freeAmt;
        escrow[u] = escrowAmt;
        total[u]  = freeAmt + escrowAmt;
    }
}

// Observable vault mock to track slashes
contract MockVault is IWrVault {
    mapping(address => uint256) public slashed;
    function slashFromOracle(address user, uint256 amount) external {
        slashed[user] += amount;
    }
}

contract Oracle_Sync_Edges is Test {
    MockRBTCToken token;
    MockVault     vault;
    rBTCOracle    oracle;

    address op   = address(0xBEEF);
    address user = address(0xAAA);

    function setUp() public {
        token  = new MockRBTCToken();
        vault  = new MockVault();
        oracle = new rBTCOracle(address(token), address(vault), bytes32(0));
        oracle.setOperator(op, true);
    }

    function test_OnlyOperator_Guard() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(rBTCOracle.OnlyOperator.selector);
        oracle.syncVerifiedTotal(user, 123, 1);
    }

    function test_NoOp_WhenTotalsEqual_And_RoundUpdate() public {
        // Seed: total = 100 (all free)
        token._seed(user, 100, 0);

        // Equal total => no state change except round
        vm.prank(op);
        oracle.syncVerifiedTotal(user, 100, 42);

        assertEq(token.freeBalanceOf(user), 100, "free unchanged");
        assertEq(token.totalBackedOf(user), 100, "total unchanged");
        assertEq(oracle.lastVerifiedRound(user), 42, "round stored");

        // round=0 should NOT overwrite stored round
        vm.prank(op);
        oracle.syncVerifiedTotal(user, 100, 0);
        assertEq(oracle.lastVerifiedRound(user), 42, "round not overwritten by zero");
    }

    function test_Increase_MintsToFree() public {
        // Start at 0
        assertEq(token.totalBackedOf(user), 0, "initial total must be zero");

        vm.prank(op);
        oracle.syncVerifiedTotal(user, 250, 1);

        assertEq(token.freeBalanceOf(user), 250, "minted to free");
        assertEq(token.totalBackedOf(user), 250, "total equals target");
    }

    function test_Decrease_BurnFromFreeOnly() public {
        // Seed: free=80, escrow=0 => total=80
        token._seed(user, 80, 0);

        // Target 30 => burn 50 from free
        vm.prank(op);
        oracle.syncVerifiedTotal(user, 30, 7);

        assertEq(token.freeBalanceOf(user), 30, "free reduced to target");
        assertEq(token.totalBackedOf(user), 30, "total equals target");
        assertEq(vault.slashed(user), 0, "no slash when free was enough");
    }

    function test_Decrease_BurnThenSlashEscrow() public {
        // Seed: free=80, escrow=40 => total=120
        token._seed(user, 80, 40);

        // Target 30 => delta=90: burn 80 from free, then slash 10 and debit escrow 10
        vm.prank(op);
        oracle.syncVerifiedTotal(user, 30, 9);

        assertEq(token.freeBalanceOf(user), 0,  "free fully burned first");
        assertEq(token.totalBackedOf(user), 30, "total equals target");
        assertEq(vault.slashed(user), 10,      "vault slashed remainder");
        // Optional: check escrow moved down by 10 (40 -> 30)
        // We cannot read escrow directly via interface, but total invariant already covers it.
    }
}