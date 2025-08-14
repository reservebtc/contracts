// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {rBTCSYNTH} from "../src/rBTCSYNTH.sol";
import {VaultWrBTC} from "../src/VaultWrBTC.sol";

/* ------------------------------------------------------------- */
/*                      Minimal oracle forwarder                  */
/* ------------------------------------------------------------- */
contract OracleForwarder {
    rBTCSYNTH public token;
    VaultWrBTC public vault;

    address public owner;

    constructor() {
        owner = msg.sender;
    }

    function init(rBTCSYNTH _token, VaultWrBTC _vault) external {
        require(msg.sender == owner, "only owner");
        require(address(token) == address(0) && address(vault) == address(0), "already initialized");
        token = _token;
        vault = _vault;
    }

    function setVaultOnToken(address v) external {
        token.setVault(v);
    }

    function mint(address to, uint256 amount) external {
        token.mintFromOracle(to, amount);
    }
}

/* ------------------------------------------------------------- */
/*                            Handler                             */
/* ------------------------------------------------------------- */
contract VaultToken_Conservation_Handler is Test {
    rBTCSYNTH public token;
    VaultWrBTC public vault;

    address[] public users;

    constructor(rBTCSYNTH _token, VaultWrBTC _vault) {
        token = _token;
        vault = _vault;

        for (uint256 i = 0; i < 5; i++) {
            address u = address(uint160(uint256(keccak256(abi.encode("USER", i)))));
            users.push(u);
        }
    }

    function _user(uint256 seed) internal view returns (address) {
        return users[seed % users.length];
    }

    /* --------------------------- actions --------------------------- */

    function actWrap(uint256 userSeed, uint256 amount) external {
        address u = _user(userSeed);
        uint256 freeBal = token.freeBalanceOf(u);
        if (freeBal == 0) return;

        amount = _clamp(amount, 1, freeBal);

        vm.startPrank(u);
        token.wrap(amount);
        vm.stopPrank();
    }

    function actRedeem(uint256 userSeed, uint256 amount) external {
        address u = _user(userSeed);
        uint256 wr = vault.balanceOf(u);
        if (wr == 0) return;

        amount = _clamp(amount, 1, wr);

        vm.startPrank(u);
        vault.redeem(amount);
        vm.stopPrank();
    }

    /* ----------------------- helpers & views ----------------------- */

    // local clamp helper to avoid name clash with forge-std's _bound
    function _clamp(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        if (max < min) return min;
        uint256 span = max - min + 1;
        if (span == 0) return min;
        return (x % span) + min;
    }

    function usersLen() external view returns (uint256) { return users.length; }
    function userAt(uint256 i) external view returns (address) { return users[i]; }
}

/* ------------------------------------------------------------- */
/*                         Invariant suite                        */
/* ------------------------------------------------------------- */
contract VaultWrBTC_Conservation_Invariant is StdInvariant, Test {
    rBTCSYNTH public token;
    VaultWrBTC public vault;
    OracleForwarder public oracle;
    VaultToken_Conservation_Handler public handler;

    mapping(address => uint256) public baselineTotal;

    function setUp() public {
        oracle = new OracleForwarder();

        token = new rBTCSYNTH(address(oracle));
        vault  = new VaultWrBTC(address(token), address(oracle));

        oracle.init(token, vault);
        oracle.setVaultOnToken(address(vault));

        handler = new VaultToken_Conservation_Handler(token, vault);
        targetContract(address(handler));

        uint256 n = handler.usersLen();
        for (uint256 i = 0; i < n; i++) {
            address u = handler.userAt(i);
            uint256 seedAmount = 1_000_000 + i * 777;
            oracle.mint(u, seedAmount);
            baselineTotal[u] = token.freeBalanceOf(u) + token.escrowOf(u);
        }
    }

    /// per-user totals conserved under wrap/redeem (no oracle during fuzz run)
    function invariant_UserTotalsConserved() public view {
        uint256 n = handler.usersLen();
        for (uint256 i = 0; i < n; i++) {
            address u = handler.userAt(i);
            uint256 currentTotal = token.freeBalanceOf(u) + token.escrowOf(u);
            assertEq(currentTotal, baselineTotal[u], "per-user total changed without oracle");
        }
    }

    /// sum(escrow) == wrBTC.totalSupply()
    function invariant_SumEscrowEqualsWrSupply() public view {
        uint256 n = handler.usersLen();
        uint256 sumEscrow = 0;
        for (uint256 i = 0; i < n; i++) {
            sumEscrow += token.escrowOf(handler.userAt(i));
        }
        assertEq(sumEscrow, vault.totalSupply(), "escrow sum != wrBTC supply");
    }

    /// 1:1 mirror between escrow and wrBTC balances
    function invariant_UserWrEqualsEscrow() public view {
        uint256 n = handler.usersLen();
        for (uint256 i = 0; i < n; i++) {
            address u = handler.userAt(i);
            assertEq(vault.balanceOf(u), token.escrowOf(u), "wrBTC != escrow");
        }
    }
}