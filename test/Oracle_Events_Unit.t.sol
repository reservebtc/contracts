// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import {rBTCOracle} from "../src/rBTCOracle.sol";

/* ---------- Minimal deps to deploy and drive the oracle ---------- */

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

/**
 * @dev Minimal token mock that tracks free/escrow/total and implements the oracle hooks.
 *      No events here: we only validate oracle events in this test suite.
 */
contract MockRBTCToken is IRBTCToken {
    mapping(address => uint256) public free;
    mapping(address => uint256) public escrow;
    mapping(address => uint256) public totals;

    function freeBalanceOf(address u) external view returns (uint256) { return free[u]; }
    function totalBackedOf(address u) external view returns (uint256) { return totals[u]; }

    function mintFromOracle(address to, uint256 amount) external { free[to] += amount; totals[to] += amount; }
    function burnFromOracle(address from, uint256 amount) external { free[from] -= amount; totals[from] -= amount; }
    function debitEscrowFromOracle(address user, uint256 amount) external { escrow[user] -= amount; totals[user] -= amount; }

    // helper: seed balances for sync paths
    function _seed(address u, uint256 freeAmt, uint256 escrowAmt) external {
        free[u] = freeAmt;
        escrow[u] = escrowAmt;
        totals[u] = freeAmt + escrowAmt;
    }
}

/**
 * @dev Minimal vault mock that accepts slashing.
 */
contract MockVault is IWrVault {
    mapping(address => uint256) public slashed;
    function slashFromOracle(address user, uint256 amount) external { slashed[user] += amount; }
}

/* ------------------------------------------------------------------ */

contract Oracle_Events_Unit is Test {
    MockRBTCToken token;
    MockVault     vault;
    rBTCOracle    oracle;

    address owner = address(this);
    address user  = address(0xAA);
    address op    = address(0xBEEF);

    /* ---------- Mirror oracle events to assert with expectEmit ---------- */
    event OwnerChanged(address indexed newOwner);
    event OperatorSet(address indexed op, bool enabled);
    event MerkleRootUpdated(bytes32 root);

    function setUp() public {
        token = new MockRBTCToken();
        vault = new MockVault();

        // Constructor is expected to emit OwnerChanged(owner) and OperatorSet(owner, true).
        vm.expectEmit(true, false, false, true);
        emit OwnerChanged(owner);
        vm.expectEmit(true, false, false, true);
        emit OperatorSet(owner, true);

        // Root is zero here => no MerkleRootUpdated on this deployment.
        oracle = new rBTCOracle(address(token), address(vault), bytes32(0));
    }

    /* ---------- Constructor (non-zero root path) ---------- */

    function test_Constructor_EmitsMerkleRoot_WhenNonZero() public {
        bytes32 root = keccak256("root");

        // Expect events for a fresh deployment with non-zero root.
        vm.expectEmit(false, false, false, true);
        emit MerkleRootUpdated(root);
        vm.expectEmit(true, false, false, true);
        emit OwnerChanged(address(this));
        vm.expectEmit(true, false, false, true);
        emit OperatorSet(address(this), true);

        rBTCOracle o2 = new rBTCOracle(address(token), address(vault), root);
        assertEq(o2.merkleRoot(), root, "root stored in constructor");
    }

    /* ---------- setMerkleRoot events ---------- */

    function test_Event_MerkleRootUpdated() public {
        bytes32 r1 = bytes32(uint256(123));
        vm.expectEmit(false, false, false, true);
        emit MerkleRootUpdated(r1);
        oracle.setMerkleRoot(r1);
        assertEq(oracle.merkleRoot(), r1, "root updated 1");

        bytes32 r2 = bytes32(uint256(456));
        vm.expectEmit(false, false, false, true);
        emit MerkleRootUpdated(r2);
        oracle.setMerkleRoot(r2);
        assertEq(oracle.merkleRoot(), r2, "root updated 2");
    }

    /* ---------- setOperator events (enable + disable) ---------- */

    function test_Event_OperatorSet_GrantAndRevoke() public {
        vm.expectEmit(true, false, false, true);
        emit OperatorSet(op, true);
        oracle.setOperator(op, true);
        assertTrue(oracle.isOperator(op), "operator granted");

        vm.expectEmit(true, false, false, true);
        emit OperatorSet(op, false);
        oracle.setOperator(op, false);
        assertFalse(oracle.isOperator(op), "operator revoked");
    }

    /* ---------- setOwner event (non-zero target) ---------- */

    function test_Event_OwnerChanged_OnTransferOwnership() public {
        vm.expectEmit(true, false, false, true);
        emit OwnerChanged(op);
        oracle.setOwner(op);

        // After ownership transfer, original owner cannot call onlyOwner.
        vm.expectRevert(rBTCOracle.OnlyOwner.selector);
        oracle.setOperator(address(0xCAFE), true);
    }

    /* ---------- Negative: non-owner calls must revert (no events) ---------- */

    function test_Revert_When_NonOwner_Calls_setMerkleRoot() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(rBTCOracle.OnlyOwner.selector);
        oracle.setMerkleRoot(bytes32(uint256(777)));
    }

    function test_Revert_When_NonOwner_Calls_setOperator() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(rBTCOracle.OnlyOwner.selector);
        oracle.setOperator(address(0xBAD), true);
    }

    /* ---------- Owner sets zero owner: must emit and revoke old owner ---------- */
    // NOTE: The contract allows zero owner (no revert). We assert the event and permission loss.
    function test_SetOwnerZero_EmitsAndRevokesOldOwner() public {
        vm.expectEmit(true, false, false, true);
        emit OwnerChanged(address(0));
        oracle.setOwner(address(0));

        vm.expectRevert(rBTCOracle.OnlyOwner.selector);
        oracle.setOperator(address(0xCAFE), true);
    }

    /* ---------- syncVerifiedTotal should not emit oracle admin events ---------- */

    function test_Sync_NoOracleEvents_Emitted() public {
        oracle.setOperator(op, true);
        token._seed(user, 80, 20); // total=100

        vm.recordLogs();

        // Increase total -> mint path
        vm.prank(op);
        oracle.syncVerifiedTotal(user, 150, 1);

        // Decrease total -> burn from free first
        vm.prank(op);
        oracle.syncVerifiedTotal(user, 90, 2);

        // Decrease below free -> burn + slash + debit escrow
        token._seed(user, 10, 40); // total=50
        vm.prank(op);
        oracle.syncVerifiedTotal(user, 5, 3);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "oracle must not emit events on sync");
        assertEq(oracle.lastVerifiedRound(user), 3, "round updated");
    }
}