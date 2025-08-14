// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import {rBTCOracle} from "../src/rBTCOracle.sol";

// Minimal interfaces to satisfy rBTCOracle constructor
interface IRBTCToken {
    function totalBackedOf(address) external view returns (uint256);
}
interface IWrVault {}

// Simple dummies (no behavior needed for admin/role tests)
contract DummyToken is IRBTCToken {
    mapping(address => uint256) public t;
    function totalBackedOf(address u) external view returns (uint256) { return t[u]; }
}
contract DummyVault is IWrVault {}

contract Oracle_Admin_Unit is Test {
    DummyToken token;
    DummyVault vault;
    rBTCOracle oracle;

    address owner = address(this);
    address op    = address(0xBEEF);
    address user  = address(0xAAA);

    function setUp() public {
        token  = new DummyToken();
        vault  = new DummyVault();
        oracle = new rBTCOracle(address(token), address(vault), bytes32(0));
    }

    function test_OnlyOwner_CanSetOperator() public {
        // Non-owner cannot set operator
        vm.prank(address(0xBAD));
        vm.expectRevert(rBTCOracle.OnlyOwner.selector);
        oracle.setOperator(op, true);

        // Owner sets operator
        oracle.setOperator(op, true);

        // Operator can call sync
        vm.prank(op);
        oracle.syncVerifiedTotal(user, 0, 0);
    }

    function test_TransferOwnership() public {
        // Transfer ownership to 'op'
        oracle.setOwner(op);

        // Old owner loses rights
        vm.expectRevert(rBTCOracle.OnlyOwner.selector);
        oracle.setOperator(address(1), true);

        // New owner has rights
        vm.prank(op);
        oracle.setOperator(address(1), true);
    }

    function test_SetMerkleRoot_OnlyOwner() public {
        // Guard check
        vm.prank(address(0xBAD));
        vm.expectRevert(rBTCOracle.OnlyOwner.selector);
        oracle.setMerkleRoot(bytes32(uint256(123)));

        // Happy path
        bytes32 r = bytes32(uint256(456));
        oracle.setMerkleRoot(r);
        assertEq(oracle.merkleRoot(), r, "merkle root must be updated by owner");
    }
}