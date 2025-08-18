// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import {rBTCOracle, IRBTCToken, IWrVault} from "../src/rBTCOracle.sol";

/// @dev Minimal IRBTCToken mock that tracks free/escrow and call counters.
contract MockRBTCToken is IRBTCToken {
    mapping(address => uint256) internal _free;
    mapping(address => uint256) internal _escrow;

    uint256 public mintCalls;
    uint256 public burnCalls;
    uint256 public debitCalls;

    // --- IRBTCToken (views) ---
    function freeBalanceOf(address u) external view returns (uint256) { return _free[u]; }
    function escrowOf(address u) external view returns (uint256) { return _escrow[u]; }
    function totalBackedOf(address u) public view returns (uint256) { return _free[u] + _escrow[u]; }

    // --- IRBTCToken (state changers) ---
    function mintFromOracle(address to, uint256 amount) external {
        _free[to] += amount;
        mintCalls++;
    }

    function burnFromOracle(address from, uint256 amount) external {
        require(_free[from] >= amount, "free < amount");
        _free[from] -= amount;
        burnCalls++;
    }

    function debitEscrowFromOracle(address user, uint256 amount) external {
        require(_escrow[user] >= amount, "escrow < amount");
        _escrow[user] -= amount;
        debitCalls++;
    }

    // --- helpers for tests ---
    function setBalances(address u, uint256 freeAmt, uint256 escrowAmt) external {
        _free[u] = freeAmt;
        _escrow[u] = escrowAmt;
    }
}

/// @dev Minimal IWrVault mock that records slashed amounts.
contract MockVault is IWrVault {
    mapping(address => uint256) public slashedOf;

    function slashFromOracle(address user, uint256 amount) external {
        slashedOf[user] += amount;
    }
}

contract Oracle_Resilience_Unit is Test {
    rBTCOracle internal oracle;
    MockRBTCToken internal token;
    MockVault internal vault;

    address internal constant USER = address(0xBEEF);

    function setUp() public {
        token = new MockRBTCToken();
        vault = new MockVault();
        // merkleRoot = 0 for tests
        oracle = new rBTCOracle(address(token), address(vault), bytes32(0));
        // msg.sender (this test contract) is owner & operator by constructor
    }

    /// @notice Deficit exceeds free: free burns to zero, remainder is slashed+debited from escrow.
    function test_Sync_BurnsFreeToZero_ThenSlashAndDebit_WhenDeficitExceedsFree() public {
        // Arrange: free=1_000, escrow=600, curTotal=1_600
        token.setBalances(USER, 1_000, 600);

        uint256 targetTotal = 400; // toBurn = 1_600 - 400 = 1_200 > free(1_000)
        uint64 round = 42;

        // Act
        oracle.syncVerifiedTotal(USER, targetTotal, round);

        // Assert: free -> 0, escrow -> 600 - (1_200 - 1_000) = 400
        assertEq(token.freeBalanceOf(USER), 0, "free should be zero");
        assertEq(token.escrowOf(USER), 400, "escrow should decrease by remainder");
        assertEq(token.totalBackedOf(USER), targetTotal, "totalBacked must match target");

        // Vault slashed exactly the escrow remainder (200)
        assertEq(vault.slashedOf(USER), 200, "vault slash mismatch");

        // Call counters: burn once (1000), debit once (200), no mint
        assertEq(token.mintCalls(), 0, "mint should not be called");
        assertEq(token.burnCalls(), 1, "burn should be called once");
        assertEq(token.debitCalls(), 1, "debitEscrow should be called once");
        // Round persisted
        assertEq(oracle.lastVerifiedRound(USER), round, "round should be recorded");
    }

    /// @notice Repeating sync with the same (total, round) is a no-op.
    function test_Sync_Idempotent_WhenSameTotalAndRound() public {
        // Arrange: free=500, escrow=300, curTotal=800
        token.setBalances(USER, 500, 300);
        uint256 total = 800;
        uint64 round = 77;

        // First call (no changes expected because target == current)
        oracle.syncVerifiedTotal(USER, total, round);

        // Snapshot after first call
        uint256 free1   = token.freeBalanceOf(USER);
        uint256 escrow1 = token.escrowOf(USER);
        uint256 mint1   = token.mintCalls();
        uint256 burn1   = token.burnCalls();
        uint256 debit1  = token.debitCalls();
        uint256 slashed1 = vault.slashedOf(USER);
        uint64  storedRound1 = oracle.lastVerifiedRound(USER);

        // Second call with identical (total, round)
        oracle.syncVerifiedTotal(USER, total, round);

        // Assert: absolutely no state deltas
        assertEq(token.freeBalanceOf(USER), free1, "free changed on idempotent sync");
        assertEq(token.escrowOf(USER), escrow1, "escrow changed on idempotent sync");
        assertEq(vault.slashedOf(USER), slashed1, "slash changed on idempotent sync");
        assertEq(token.mintCalls(),  mint1,  "mintCalls changed on idempotent sync");
        assertEq(token.burnCalls(),  burn1,  "burnCalls changed on idempotent sync");
        assertEq(token.debitCalls(), debit1, "debitCalls changed on idempotent sync");
        assertEq(oracle.lastVerifiedRound(USER), storedRound1, "round changed on idempotent sync");
    }
}