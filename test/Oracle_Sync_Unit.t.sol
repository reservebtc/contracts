// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import {IReserveProofOracle} from "../src/IReserveProofOracle.sol";
import {rBTCOracle} from "../src/rBTCOracle.sol";

interface IRBTCToken {
    function freeBalanceOf(address u) external view returns (uint256);
    function escrowOf(address u) external view returns (uint256);
    function totalBackedOf(address u) external view returns (uint256);

    function mintFromOracle(address to, uint256 amount) external;
    function burnFromOracle(address from, uint256 amount) external;
    function debitEscrowFromOracle(address user, uint256 amount) external;
}

interface IWrVault {
    function slashFromOracle(address user, uint256 amount) external;
}

// --- Minimal mocks to isolate oracle logic ---
contract MockRBTCToken is IRBTCToken {
    mapping(address => uint256) public freeBal;
    mapping(address => uint256) public escBal;

    function freeBalanceOf(address u) external view returns (uint256) { return freeBal[u]; }
    function escrowOf(address u) external view returns (uint256) { return escBal[u]; }
    function totalBackedOf(address u) public view returns (uint256) { return freeBal[u] + escBal[u]; }

    function mintFromOracle(address to, uint256 amount) external { freeBal[to] += amount; }
    function burnFromOracle(address from, uint256 amount) external { freeBal[from] -= amount; }
    function debitEscrowFromOracle(address user, uint256 amount) external { escBal[user] -= amount; }

    // helpers for tests
    function wrap(address user, uint256 amount) external {
        require(freeBal[user] >= amount, "insufficient");
        freeBal[user] -= amount;
        escBal[user] += amount;
    }
}

contract MockVault is IWrVault {
    mapping(address => uint256) public wr;
    uint256 public total;

    function slashFromOracle(address user, uint256 amount) external {
        require(wr[user] >= amount, "insufficient");
        wr[user] -= amount;
        total    -= amount;
    }

    // helpers to simulate onWrap
    function onWrap(address user, uint256 amount) external {
        wr[user] += amount;
        total    += amount;
    }
}

contract Oracle_Sync_Unit is Test {
    MockRBTCToken internal t;
    MockVault     internal v;
    rBTCOracle    internal o;

    address internal owner = address(this);
    address internal op    = address(this);
    address internal user  = address(0xAAA);

    function setUp() public {
        t = new MockRBTCToken();
        v = new MockVault();
        // initial merkle root = 0
        o = new rBTCOracle(address(t), address(v), bytes32(0));
        // Already operator = owner in constructor
    }

    function test_Sync_Mint_OnIncrease() public {
        // current = 0 -> newTotal = 10_000
        o.syncVerifiedTotal(user, 10_000, 1);
        assertEq(t.freeBalanceOf(user), 10_000);
        assertEq(t.escrowOf(user), 0);
        assertEq(t.totalBackedOf(user), 10_000);
    }

    function test_Sync_Burn_FromFree_First() public {
        // start with free=8_000
        o.syncVerifiedTotal(user, 8_000, 1);
        // decrease to 5_500 -> burn 2_500 from free
        o.syncVerifiedTotal(user, 5_500, 2);
        assertEq(t.freeBalanceOf(user), 5_500);
        assertEq(t.escrowOf(user), 0);
    }

    function test_Sync_Burn_ThenSlashEscrow() public {
        // start with 10_000 and wrap 7_000 -> escrow=7k, free=3k
        o.syncVerifiedTotal(user, 10_000, 1);
        t.wrap(user, 7_000);
        v.onWrap(user, 7_000);
        // drop to 2_000: need to remove 8_000 (free burn 3k, slash 5k)
        o.syncVerifiedTotal(user, 2_000, 2);

        assertEq(t.freeBalanceOf(user), 0);
        assertEq(t.escrowOf(user), 2_000); // 7k - 5k slashed
        assertEq(v.total(), 2_000);
    }

    function testFuzz_Sync_RandomMonotonic(uint96 start, uint96 inc1, uint96 dec1) public {
        // normalize
        start = uint96(bound(start, 0, 1e12));
        inc1  = uint96(bound(inc1, 0, 1e12));
        dec1  = uint96(bound(dec1, 0, start + inc1));

        // start
        o.syncVerifiedTotal(user, start, 1);
        assertEq(t.totalBackedOf(user), start);

        // increase
        o.syncVerifiedTotal(user, start + inc1, 2);
        assertEq(t.totalBackedOf(user), start + inc1);

        // simulate partial wrap up to 70% of total
        uint256 wrapAmt = (t.totalBackedOf(user) * 70) / 100;
        if (wrapAmt > t.freeBalanceOf(user)) wrapAmt = t.freeBalanceOf(user);
        t.wrap(user, wrapAmt);
        v.onWrap(user, wrapAmt);

        // decrease
        uint256 newTotal = uint256(start + inc1) - dec1;
        o.syncVerifiedTotal(user, newTotal, 3);

        // Invariant: free + escrow == newTotal
        assertEq(t.totalBackedOf(user), newTotal);
        // Invariant: vault.total == escrow (since redeem not modeled here)
        assertEq(v.total(), t.escrowOf(user));
    }
}
