// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {rBTCSYNTH} from "../src/rBTCSYNTH.sol";
import {VaultWrBTC} from "../src/VaultWrBTC.sol";

/* ------------------------------------------------------------- */
/*                         Oracle forwarder                      */
/* ------------------------------------------------------------- */
/**
 * @notice Minimal oracle forwarder. Deployed once; token/vault are wired via init().
 *         This contract's address is used as `oracle` inside token & vault.
 */
contract OracleForwarder {
    rBTCSYNTH public token;
    VaultWrBTC public vault;

    address public owner;

    constructor() {
        owner = msg.sender;
    }

    function init(rBTCSYNTH _token, VaultWrBTC _vault) external {
        require(msg.sender == owner, "only owner");
        require(address(token) == address(0) && address(vault) == address(0), "already inited");
        token = _token;
        vault = _vault;
    }

    // --- oracle-only flows (seen by token/vault as msg.sender=this) ---
    function setVaultOnToken(address v) external {
        token.setVault(v);
    }

    function mint(address to, uint256 amount) external {
        token.mintFromOracle(to, amount);
    }

    function slashAndDebit(address user, uint256 amount) external {
        vault.slashFromOracle(user, amount);
        token.debitEscrowFromOracle(user, amount);
    }
}

/* ------------------------------------------------------------- */
/*                            Handler                            */
/* ------------------------------------------------------------- */
contract VaultToken_Handler is Test {
    rBTCSYNTH public token;
    VaultWrBTC public vault;
    OracleForwarder public oracle;

    address[] public users;
    mapping(address => uint256) public expectedTotal; // free + escrow per user (oracle-adjusted)

    constructor(rBTCSYNTH _token, VaultWrBTC _vault, OracleForwarder _oracle) {
        token = _token;
        vault = _vault;
        oracle = _oracle;

        // Deterministic pseudo-users
        for (uint256 i = 0; i < 5; i++) {
            address u = address(uint160(uint256(keccak256(abi.encode("USER", i)))));
            users.push(u);
        }
    }

    function _u(uint256 idx) internal view returns (address) {
        return users[idx % users.length];
    }

    // --- actions ---

    function opMintFromOracle(uint256 userSeed, uint256 amtSeed) external {
        address u = _u(userSeed);
        uint256 amount = bound(amtSeed, 1, 1_000_000);
        oracle.mint(u, amount);
        expectedTotal[u] += amount;
    }

    function actWrap(uint256 userSeed, uint256 amtSeed) external {
        address u = _u(userSeed);
        uint256 freeBal = token.freeBalanceOf(u);
        if (freeBal == 0) return;
        uint256 amount = bound(amtSeed, 1, freeBal);
        vm.startPrank(u);
        token.wrap(amount);
        vm.stopPrank();
        // total unchanged (moves from free to escrow)
    }

    function actRedeem(uint256 userSeed, uint256 amtSeed) external {
        address u = _u(userSeed);
        uint256 wrBal = vault.balanceOf(u);
        if (wrBal == 0) return;
        uint256 amount = bound(amtSeed, 1, wrBal);
        vm.startPrank(u);
        vault.redeem(amount);
        vm.stopPrank();
        // total unchanged (moves from escrow to free)
    }

    function opSlashAndDebit(uint256 userSeed, uint256 amtSeed) external {
        address u = _u(userSeed);
        uint256 esc = token.escrowOf(u);
        if (esc == 0) return;
        uint256 amount = bound(amtSeed, 1, esc);
        oracle.slashAndDebit(u, amount);
        expectedTotal[u] -= amount;
    }

    // --- views for invariants ---
    function usersLen() external view returns (uint256) { return users.length; }
    function userAt(uint256 i) external view returns (address) { return users[i]; }
}

/* ------------------------------------------------------------- */
/*                         Invariant test                        */
/* ------------------------------------------------------------- */
contract VaultWrBTC_Fuzz_Invariant is StdInvariant, Test {
    rBTCSYNTH public token;
    VaultWrBTC public vault;
    OracleForwarder public oracle;
    VaultToken_Handler public handler;

    function setUp() public {
        // 1) Deploy oracle forwarder first (address fixed forever)
        oracle = new OracleForwarder();

        // 2) Deploy token/vault with oracle == oracleForwarder address
        token  = new rBTCSYNTH(address(oracle));
        vault  = new VaultWrBTC(address(token), address(oracle));

        // 3) Wire token<->vault via oracle call
        oracle.init(token, vault);
        oracle.setVaultOnToken(address(vault));

        // 4) Handler & invariant targets
        handler = new VaultToken_Handler(token, vault, oracle);
        targetContract(address(handler)); // let Foundry pick any handler actions
    }

    /// @notice For every tracked user: free + escrow equals expected total.
    function invariant_UserTotalsMatchExpected() public view {
        uint256 n = handler.usersLen();
        for (uint256 i = 0; i < n; i++) {
            address u = handler.userAt(i);
            uint256 freeBal = token.freeBalanceOf(u);
            uint256 escBal  = token.escrowOf(u);
            uint256 expected = handler.expectedTotal(u);
            assertEq(freeBal + escBal, expected, "user total mismatch");
        }
    }

    /// @notice Global escrow sum equals wrBTC totalSupply.
    function invariant_SumEscrowEqualsWrSupply() public view {
        uint256 n = handler.usersLen();
        uint256 sumEscrow = 0;
        for (uint256 i = 0; i < n; i++) {
            address u = handler.userAt(i);
            sumEscrow += token.escrowOf(u);
        }
        assertEq(sumEscrow, vault.totalSupply(), "escrow sum != wrBTC supply");
    }

    /// @notice For every user: wrBTC balance mirrors escrow 1:1 at all times.
    function invariant_UserWrEqualsEscrow() public view {
        uint256 n = handler.usersLen();
        for (uint256 i = 0; i < n; i++) {
            address u = handler.userAt(i);
            uint256 wr  = vault.balanceOf(u);
            uint256 esc = token.escrowOf(u);
            assertEq(wr, esc, "wrBTC balance must equal escrow");
        }
    }
}