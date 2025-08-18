// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import {rBTCOracle} from "../src/rBTCOracle.sol";
import {IRBTCToken, IWrVault} from "../src/rBTCOracle.sol";

/// @dev Minimal mock for IRBTCToken: does nothing on oracle calls.
/// We don't need state transitions here because we test ONLY access control.
contract MockRBTCToken is IRBTCToken {
    mapping(address => uint256) internal _free;
    mapping(address => uint256) internal _escrow;

    function freeBalanceOf(address u) external view returns (uint256) { return _free[u]; }
    function escrowOf(address u) external view returns (uint256) { return _escrow[u]; }
    function totalBackedOf(address u) external view returns (uint256) { return _free[u] + _escrow[u]; }

    function mintFromOracle(address to, uint256 amount) external { _free[to] += amount; }
    function burnFromOracle(address from, uint256 amount) external { 
        require(_free[from] >= amount, "free<amount"); 
        _free[from] -= amount; 
    }
    function debitEscrowFromOracle(address user, uint256 amount) external { 
        require(_escrow[user] >= amount, "escrow<amount"); 
        _escrow[user] -= amount; 
    }
}

/// @dev Minimal mock for IWrVault: also no-op (slash is allowed).
contract MockVault is IWrVault {
    mapping(address => uint256) public burned;
    function slashFromOracle(address user, uint256 amount) external { burned[user] += amount; }
}

contract Oracle_Access_Control_Unit is Test {
    rBTCOracle internal oracle;
    MockRBTCToken internal token;
    MockVault internal vault;

    address internal owner0 = address(this);
    address internal newOwner = address(0xBEEF);
    address internal someOp  = address(0xCAFE);
    address internal user    = address(0xABCD);

    function setUp() public {
        token = new MockRBTCToken();
        vault = new MockVault();
        // merkleRoot = 0 initially
        oracle = new rBTCOracle(address(token), address(vault), bytes32(0));
    }

    /* ---------- After setOwner(new), old owner must be fully revoked ---------- */

    function test_Revoke_OldOwner_After_Transfer() public {
        // Sanity: current owner is this contract; transfer ownership to newOwner
        oracle.setOwner(newOwner);

        // Old owner tries to set operator -> must revert
        vm.expectRevert(rBTCOracle.OnlyOwner.selector);
        oracle.setOperator(someOp, true);

        // Old owner tries to set merkle root -> must revert
        vm.expectRevert(rBTCOracle.OnlyOwner.selector);
        oracle.setMerkleRoot(keccak256("root"));

        // New owner can act
        vm.prank(newOwner);
        oracle.setOperator(someOp, true);

        vm.prank(newOwner);
        oracle.setMerkleRoot(keccak256("root2"));
    }

    /* ---------- Disabling operator must immediately block sync ---------- */

    function test_Operator_Disable_Blocks_Sync_Immediately() public {
        // Owner grants operator role to someOp
        oracle.setOperator(someOp, true);

        // Now owner immediately revokes it
        oracle.setOperator(someOp, false);

        // The same operator address must be blocked right away
        vm.prank(someOp);
        vm.expectRevert(rBTCOracle.OnlyOperator.selector);
        oracle.syncVerifiedTotal(user, 123, 1);
    }
}