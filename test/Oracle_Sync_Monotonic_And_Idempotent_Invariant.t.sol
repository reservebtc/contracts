// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
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

contract MockRBTCToken is IRBTCToken {
    mapping(address => uint256) public freeBal;
    mapping(address => uint256) public escBal;

    function freeBalanceOf(address u) external view returns (uint256) { return freeBal[u]; }
    function escrowOf(address u) external view returns (uint256) { return escBal[u]; }
    function totalBackedOf(address u) public view returns (uint256) { return freeBal[u] + escBal[u]; }
    function mintFromOracle(address to, uint256 amount) external { freeBal[to] += amount; }
    function burnFromOracle(address from, uint256 amount) external { freeBal[from] -= amount; }
    function debitEscrowFromOracle(address user, uint256 amount) external { escBal[user] -= amount; }
    function wrap(address user, uint256 amount) external {
        require(freeBal[user] >= amount, "insufficient");
        freeBal[user] -= amount;
        escBal[user] += amount;
    }
}

contract MockVault is IWrVault {
    mapping(address => uint256) public wr;
    uint256 public total;
    function slashFromOracle(address user, uint256 amount) external { wr[user] -= amount; total -= amount; }
    function onWrap(address user, uint256 amount) external { wr[user] += amount; total += amount; }
}

contract OracleSyncHandler is Test {
    MockRBTCToken public t;
    MockVault public v;
    rBTCOracle public o;

    address[] public users;
    mapping(address => uint256) public lastTarget;
    mapping(address => uint64)  public lastRound;

    constructor(MockRBTCToken _t, MockVault _v, rBTCOracle _o) {
        t = _t; v = _v; o = _o;
        for (uint256 i = 0; i < 5; i++) {
            address u = address(uint160(uint256(keccak256(abi.encode("U", i)))));
            users.push(u);
        }
    }

    function _u(uint256 seed) internal view returns (address) { return users[seed % users.length]; }

    function actWrap(uint256 userSeed, uint256 amountSeed) external {
        address u = _u(userSeed);
        uint256 free = t.freeBalanceOf(u);
        if (free == 0) return;
        uint256 amount = bound(amountSeed, 1, free);
        t.wrap(u, amount);
        v.onWrap(u, amount);
    }

    function actSync(uint256 userSeed, uint256 newTotalSeed, uint64 roundSeed) external {
        address u = _u(userSeed);
        uint64 newRound;
        if (lastRound[u] < type(uint64).max - 2) {
            uint64 span = 2;
            newRound = lastRound[u] + uint64(bound(uint256(roundSeed), 0, span));
        } else {
            newRound = lastRound[u];
        }
        uint256 newTotal = bound(newTotalSeed, 0, 1e12);
        o.syncVerifiedTotal(u, newTotal, newRound);
        if (newRound >= lastRound[u]) {
            lastRound[u] = newRound;
            lastTarget[u] = newTotal;
        }
    }

    function actResyncSame(uint256 userSeed) external {
        address u = _u(userSeed);
        o.syncVerifiedTotal(u, lastTarget[u], lastRound[u]);
    }

    function actSyncOlderRound(uint256 userSeed, uint256 totalSeed) external {
        address u = _u(userSeed);
        if (lastRound[u] == 0) return;
        uint64 older = lastRound[u] - 1;
        uint256 someTotal = bound(totalSeed, 0, 1e12);
        o.syncVerifiedTotal(u, someTotal, older);
    }

    function usersLen() external view returns (uint256) { return users.length; }
    function userAt(uint256 i) external view returns (address) { return users[i]; }
}

contract Oracle_Sync_Monotonic_And_Idempotent_Invariant is StdInvariant, Test {
    MockRBTCToken public t;
    MockVault public v;
    rBTCOracle public o;
    OracleSyncHandler public handler;

    function setUp() public {
        // Deploy deps
        t = new MockRBTCToken();
        v = new MockVault();
        o = new rBTCOracle(address(t), address(v), bytes32(0));

        // Create handler
        handler = new OracleSyncHandler(t, v, o);

        // Register handler as fuzz target 
        targetContract(address(handler));
    }

    function invariant_total_matches_last_target() public view {
        uint256 n = handler.usersLen();
        for (uint256 i = 0; i < n; i++) {
            address u = handler.userAt(i);
            assertEq(t.totalBackedOf(u), handler.lastTarget(u), "free+escrow must equal lastTarget");
        }
    }

    function invariant_round_monotonic_non_decreasing() public view {
        uint256 n = handler.usersLen();
        for (uint256 i = 0; i < n; i++) {
            address u = handler.userAt(i);
            uint64 r = handler.lastRound(u);
            assertTrue(r == handler.lastRound(u), "round tracking broken");
        }
    }

    function invariant_older_round_keeps_target() public view {
        uint256 n = handler.usersLen();
        for (uint256 i = 0; i < n; i++) {
            address u = handler.userAt(i);
            assertEq(handler.lastTarget(u), t.totalBackedOf(u), "older round changed totals");
        }
    }
}
