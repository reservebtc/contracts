// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import {rBTCOracle} from "../src/rBTCOracle.sol";

interface IRBTCToken {
    function freeBalanceOf(address u) external view returns (uint256);
    function escrowOf(address u) external view returns (uint256);
    function totalBackedOf(address u) external view returns (uint256);

    function mintFromOracle(address to, uint256 amount) external;
    function burnFromOracle(address from, uint256 amount) external;
    function debitEscrowFromOracle(address user, uint256 amount) external;

    // helper for handler
    function wrap(address user, uint256 amount) external;
}

interface IWrVault {
    function slashFromOracle(address user, uint256 amount) external;
    function onWrap(address user, uint256 amount) external;
    function total() external view returns (uint256);
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
    uint256 public _total;

    function slashFromOracle(address user, uint256 amount) external {
        require(wr[user] >= amount, "insufficient");
        wr[user] -= amount;
        _total   -= amount;
    }

    function onWrap(address user, uint256 amount) external {
        wr[user] += amount;
        _total   += amount;
    }

    function total() external view returns (uint256) { return _total; }
}

// Handler generates random actions simulating oracle sync and user wraps
contract Handler {
    rBTCOracle public oracle;
    MockRBTCToken public token;
    MockVault public vault;

    address public immutable user;

    constructor(rBTCOracle _o, MockRBTCToken _t, MockVault _v, address _user) {
        oracle = _o; token = _t; vault = _v; user = _user;
    }

    function act(uint256 seed) external {
        // randomize scenario
        uint256 cur = token.totalBackedOf(user);
        uint256 choice = seed % 4;

        if (choice == 0) {
            // increase by up to 10%
            uint256 inc = (cur * (seed % 10)) / 100 + 1;
            oracle.syncVerifiedTotal(user, cur + inc, uint64(block.number));
        } else if (choice == 1) {
            // decrease by up to current
            if (cur == 0) return;
            uint256 dec = (seed % (cur + 1));
            oracle.syncVerifiedTotal(user, cur - dec, uint64(block.number));
        } else if (choice == 2) {
            // wrap up to 70% of free
            uint256 free = token.freeBalanceOf(user);
            if (free == 0) return;
            uint256 amt = (free * (30 + (seed % 41))) / 100; // 30%..70%
            token.wrap(user, amt);
            vault.onWrap(user, amt);
        } else {
            // tiny no-op sync
            oracle.syncVerifiedTotal(user, cur, uint64(block.number));
        }
    }
}

contract Oracle_Invariant is StdInvariant, Test {
    MockRBTCToken internal t;
    MockVault     internal v;
    rBTCOracle    internal o;
    Handler       internal h;

    address internal user = address(0xAAA);

    function setUp() public {
        t = new MockRBTCToken();
        v = new MockVault();
        o = new rBTCOracle(address(t), address(v), bytes32(0)); // owner=address(this) as operator
        h = new Handler(o, t, v, user);
        targetContract(address(h));
    }

    function invariant_TotalEqualsFreePlusEscrow() public view {
        // by construction true, but ensure solidity arithmetic stable during fuzz
        uint256 total = t.totalBackedOf(user);
        uint256 free  = t.freeBalanceOf(user);
        uint256 esc   = t.escrowOf(user);
        assertEq(total, free + esc, "sum mismatch");
    }

    function invariant_VaultTotalEqualsEscrow() public view {
        assertEq(v.total(), t.escrowOf(user), "vault/escrow mismatch");
    }
}
