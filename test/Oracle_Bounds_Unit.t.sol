// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

// Foundry
import "forge-std/Test.sol";

// ====== Minimal interfaces matching your contracts ======
interface IRBTCToken {
    // views
    function freeBalanceOf(address u) external view returns (uint256);
    function escrowOf(address u) external view returns (uint256);
    function totalBackedOf(address u) external view returns (uint256);

    // oracle-only
    function mintFromOracle(address to, uint256 amount) external;
    function burnFromOracle(address from, uint256 amount) external;
    function debitEscrowFromOracle(address user, uint256 amount) external;

    // rBTCSYNTH extras (used in test wiring)
    function wrap(uint256 amount) external;
    function unwrapFromVault(address to, uint256 amount) external;
}

interface IWrVault {
    function slashFromOracle(address user, uint256 amount) external;
    function redeem(uint256 amount) external;
}

interface IVaultSetterLike {
    function setVault(address v) external;
}

// ====== Deps from your src/ ======
import {rBTCSYNTH} from "../src/rBTCSYNTH.sol";
import {VaultWrBTC} from "../src/VaultWrBTC.sol";

// A tiny oracle forwarder used ONLY in tests to reproduce rBTCOracle.sync logic
contract OracleForwarder {
    IRBTCToken public token;
    IWrVault public vault;
    address public owner = msg.sender;

    function setLinks(IRBTCToken _token, IWrVault _vault) external {
        require(msg.sender == owner, "owner");
        token = _token;
        vault = _vault;
    }

    // one-shot: set vault inside rBTCSYNTH (onlyOracle there)
    function setVaultOnToken(address v) external {
        IVaultSetterLike(address(token)).setVault(v);
    }

    // same algorithm as rBTCOracle.syncVerifiedTotal (shortened: no events/round tracking)
    function syncVerifiedTotal(address user, uint256 newTotal) external {
        uint256 curTotal = token.totalBackedOf(user);
        if (newTotal > curTotal) {
            token.mintFromOracle(user, newTotal - curTotal);
        } else if (newTotal < curTotal) {
            uint256 toBurn = curTotal - newTotal;

            uint256 free = token.freeBalanceOf(user);
            uint256 burnFree = free >= toBurn ? toBurn : free;
            if (burnFree > 0) {
                token.burnFromOracle(user, burnFree);
                toBurn -= burnFree;
            }
            if (toBurn > 0) {
                // force-burn wrBTC and debit escrow
                vault.slashFromOracle(user, toBurn);
                token.debitEscrowFromOracle(user, toBurn);
            }
        }
    }
}

contract Oracle_Bounds_Unit is Test {
    rBTCSYNTH internal t;
    VaultWrBTC internal v;
    OracleForwarder internal fwd;

    address internal alice = address(0xA11CE);

    function setUp() public {
        // 1) Deploy forwarder first (will be the oracle address for token & vault)
        fwd = new OracleForwarder();

        // 2) Deploy token & vault wiring them to the forwarder as oracle
        t = new rBTCSYNTH(address(fwd));
        v = new VaultWrBTC(address(t), address(fwd));

        // 3) Link inside forwarder & set vault on token (onlyOracle)
        fwd.setLinks(IRBTCToken(address(t)), IWrVault(address(v)));

        // forwarder must be msg.sender == oracle inside rBTCSYNTH
        vm.prank(address(fwd));
        fwd.setVaultOnToken(address(v));
    }

    // --- 1) Explicit Max-1/Max path on mint, wrap, redeem ---
    function test_Mint_Wrap_Redeem_AtBoundary_MaxAndMaxMinus1() public {
        uint256 MAX = type(uint256).max;

        // mint MAX-1
        vm.prank(address(fwd));
        t.mintFromOracle(alice, MAX - 1);
        assertEq(t.freeBalanceOf(alice), MAX - 1, "free should be MAX-1");

        // mint +1 => exactly MAX
        vm.prank(address(fwd));
        t.mintFromOracle(alice, 1);
        assertEq(t.freeBalanceOf(alice), MAX, "free should be MAX");

        // an extra +1 would overflow and revert with Panic(0x11)
        vm.expectRevert(); // generic catch (panic)
        vm.prank(address(fwd));
        t.mintFromOracle(alice, 1);

        // wrap all MAX into escrow/wrBTC
        vm.prank(alice);
        t.wrap(MAX);
        assertEq(t.freeBalanceOf(alice), 0, "free should be 0 after wrap");
        assertEq(t.escrowOf(alice), MAX, "escrow should be MAX after wrap");

        // redeem all MAX back to free
        vm.prank(alice);
        v.redeem(MAX);
        assertEq(t.escrowOf(alice), 0, "escrow should be 0 after redeem");
        assertEq(t.freeBalanceOf(alice), MAX, "free should be MAX after redeem");
    }

    // --- 2) Bounded fuzz near upper limits (large values but safe window) ---
    function testFuzz_Mint_Wrap_Redeem_UpperBounds(uint256 x) public {
        // Lower bound set to 2 so that `amt/2` is >= 1 and wrap() never gets 0
        uint256 amt = bound(x, 2, type(uint128).max); // huge range; safe per-step

        // mint -> wrap half -> redeem half -> balances stay consistent
        vm.prank(address(fwd));
        t.mintFromOracle(alice, amt);
        assertEq(t.freeBalanceOf(alice), amt);

        uint256 half = amt / 2;
        vm.prank(alice);
        t.wrap(half);
        assertEq(t.freeBalanceOf(alice), amt - half, "free after wrap");
        assertEq(t.escrowOf(alice), half, "escrow after wrap");

        vm.prank(alice);
        v.redeem(half);
        assertEq(t.freeBalanceOf(alice), amt, "free restored");
        assertEq(t.escrowOf(alice), 0, "escrow cleared");
    }

    // --- 3) Long path: many small sync steps up and down ---
    function test_LongPath_ManySmallSyncs() public {
        // forwarder plays the role of oracle sync, tiny steps to reach big total and back
        uint256 steps = 1000;
        uint256 target;
        for (uint256 i = 0; i < steps; i++) {
            target += 1;
            fwd.syncVerifiedTotal(alice, target);
            assertEq(t.totalBackedOf(alice), target, "total after up-step");
        }
        for (uint256 j = 0; j < steps; j++) {
            target -= 1;
            fwd.syncVerifiedTotal(alice, target);
            assertEq(t.totalBackedOf(alice), target, "total after down-step");
        }
        // end at zero
        assertEq(t.freeBalanceOf(alice), 0);
        assertEq(t.escrowOf(alice), 0);
        assertEq(t.totalBackedOf(alice), 0);
    }
}