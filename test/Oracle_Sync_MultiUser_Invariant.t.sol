// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {rBTCOracle} from "../src/rBTCOracle.sol";

// === Interfaces ===
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

// === Minimal mocks ===
contract MockRBTCToken is IRBTCToken {
    mapping(address => uint256) public freeBal;
    mapping(address => uint256) public escBal;

    function freeBalanceOf(address u) external view returns (uint256) {
        return freeBal[u];
    }

    function escrowOf(address u) external view returns (uint256) {
        return escBal[u];
    }

    function totalBackedOf(address u) public view returns (uint256) {
        return freeBal[u] + escBal[u];
    }

    function mintFromOracle(address to, uint256 amount) external {
        freeBal[to] += amount;
    }

    function burnFromOracle(address from, uint256 amount) external {
        freeBal[from] -= amount;
    }

    function debitEscrowFromOracle(address user, uint256 amount) external {
        escBal[user] -= amount;
    }

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
        total -= amount;
    }

    function onWrap(address user, uint256 amount) external {
        wr[user] += amount;
        total += amount;
    }
}

// === Handler for fuzzing ===
contract OracleSyncHandler is Test {
    MockRBTCToken public t;
    MockVault public v;
    rBTCOracle public o;

    address[] public users;
    mapping(address => uint256) public lastRound;

    constructor(MockRBTCToken _t, MockVault _v, rBTCOracle _o) {
        t = _t;
        v = _v;
        o = _o;

        for (uint160 i = 1; i <= 5; i++) {
            users.push(address(i));
        }
    }

    function randomUser(uint256 seed) internal view returns (address) {
        return users[seed % users.length];
    }

    function wrapSome(uint256 seed, uint256 amount) public {
        address u = randomUser(seed);
        amount = bound(amount, 0, t.freeBalanceOf(u));
        if (amount > 0) {
            t.wrap(u, amount);
            v.onWrap(u, amount);
        }
    }

    function slashSome(uint256 seed, uint256 amount) public {
        address u = randomUser(seed);
        amount = bound(amount, 0, t.escrowOf(u));
        if (amount > 0) {
            v.slashFromOracle(u, amount);
        }
    }

    function syncTotal(uint256 seed, uint256 newTotal, uint256 round) public {
        address u = randomUser(seed);
        newTotal = bound(newTotal, 0, 1e12);
        round = bound(round, lastRound[u], lastRound[u] + 2);
        o.syncVerifiedTotal(u, newTotal, uint64(round));
        if (round > lastRound[u]) lastRound[u] = round;
    }
}

// === Invariant Test ===
contract Oracle_Sync_MultiUser_Invariant is StdInvariant, Test {
    MockRBTCToken internal t;
    MockVault internal v;
    rBTCOracle internal o;
    OracleSyncHandler internal handler;

    function setUp() public {
        t = new MockRBTCToken();
        v = new MockVault();
        o = new rBTCOracle(address(t), address(v), bytes32(0));
        handler = new OracleSyncHandler(t, v, o);
        targetContract(address(handler));
    }

    function invariant_free_plus_escrow_matches_total() public {
        for (uint160 i = 1; i <= 5; i++) {
            address u = address(i);
            uint256 free = t.freeBalanceOf(u);
            uint256 esc = t.escrowOf(u);
            uint256 totalBacked = t.totalBackedOf(u);
            assertEq(free + esc, totalBacked, "free + escrow != total");
        }
    }

    function invariant_vault_total_matches_sum_escrow() public {
        uint256 sumEscrow = 0;
        for (uint160 i = 1; i <= 5; i++) {
            sumEscrow += t.escrowOf(address(i));
        }
        assertEq(sumEscrow, v.total(), "vault total != escrow sum");
    }
}