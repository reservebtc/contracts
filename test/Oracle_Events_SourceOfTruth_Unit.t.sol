// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../src/rBTCSYNTH.sol";
import "../src/VaultWrBTC.sol";

contract Oracle_Events_SourceOfTruth_Unit is Test {
    rBTCSYNTH internal token;   // rBTC-SYNTH
    VaultWrBTC internal vault;  // wrBTC vault
    address internal oracleEOA; // acts as oracle in tests
    address internal alice;

    // event topic hashes
    bytes32 constant T_Minted        = keccak256("Minted(address,uint256)");
    bytes32 constant T_Wrapped       = keccak256("Wrapped(address,uint256)");   // emitted by both vault & token
    bytes32 constant T_Unwrapped     = keccak256("Unwrapped(address,uint256)");
    bytes32 constant T_Transfer      = keccak256("Transfer(address,address,uint256)"); // ERC20 (vault)
    bytes32 constant T_Redeemed      = keccak256("Redeemed(address,uint256)");
    bytes32 constant T_Slashed       = keccak256("Slashed(address,uint256)");
    bytes32 constant T_EscrowDebited = keccak256("EscrowDebited(address,uint256)");

    function setUp() public {
        oracleEOA = address(this);
        alice = makeAddr("alice");

        token = new rBTCSYNTH(oracleEOA);
        vault = new VaultWrBTC(address(token), oracleEOA);

        // This emits VaultSet, but we DO NOT record logs yet, so it won't be checked here.
        token.setVault(address(vault));
    }

    /// Checks strict set & order of events for:
    /// mint(100) -> wrap(60) -> redeem(10) -> slash(5) + debitEscrow(5)
    function test_Events_Strict_Order_For_Canonical_Sequence() public {
        uint256 mintAmt   = 100;
        uint256 wrapAmt   = 60;
        uint256 redeemAmt = 10;
        uint256 slashAmt  = 5;

        // Start recording AFTER setUp(): VaultSet is intentionally excluded.
        vm.recordLogs();

        token.mintFromOracle(alice, mintAmt);

        vm.prank(alice);
        token.wrap(wrapAmt);

        vm.prank(alice);
        vault.redeem(redeemAmt);

        vault.slashFromOracle(alice, slashAmt);
        token.debitEscrowFromOracle(alice, slashAmt);

        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Expected 10 events, in this exact order:
        //  0: Minted                 (token)
        //  1: Transfer (mint wrBTC)  (vault)
        //  2: Wrapped                (vault)
        //  3: Wrapped                (token)
        //  4: Transfer (burn wrBTC)  (vault)  -- redeem
        //  5: Unwrapped              (token)
        //  6: Redeemed               (vault)
        //  7: Transfer (burn wrBTC)  (vault)  -- slash
        //  8: Slashed                (vault)
        //  9: EscrowDebited          (token)
        assertEq(logs.length, 10, "unexpected total number of events");

        address TOKEN = address(token);
        address VAULT = address(vault);

        // 0: Minted (token)
        assertEq(logs[0].topics[0], T_Minted, "0 topic");
        assertEq(logs[0].emitter, TOKEN, "0 emitter");

        // 1: Transfer (vault mint)
        assertEq(logs[1].topics[0], T_Transfer, "1 topic");
        assertEq(logs[1].emitter, VAULT, "1 emitter");

        // 2: Wrapped (vault)
        assertEq(logs[2].topics[0], T_Wrapped, "2 topic");
        assertEq(logs[2].emitter, VAULT, "2 emitter");

        // 3: Wrapped (token)
        assertEq(logs[3].topics[0], T_Wrapped, "3 topic");
        assertEq(logs[3].emitter, TOKEN, "3 emitter");

        // 4: Transfer (vault burn on redeem)
        assertEq(logs[4].topics[0], T_Transfer, "4 topic");
        assertEq(logs[4].emitter, VAULT, "4 emitter");

        // 5: Unwrapped (token)
        assertEq(logs[5].topics[0], T_Unwrapped, "5 topic");
        assertEq(logs[5].emitter, TOKEN, "5 emitter");

        // 6: Redeemed (vault)
        assertEq(logs[6].topics[0], T_Redeemed, "6 topic");
        assertEq(logs[6].emitter, VAULT, "6 emitter");

        // 7: Transfer (vault burn on slash)
        assertEq(logs[7].topics[0], T_Transfer, "7 topic");
        assertEq(logs[7].emitter, VAULT, "7 emitter");

        // 8: Slashed (vault)
        assertEq(logs[8].topics[0], T_Slashed, "8 topic");
        assertEq(logs[8].emitter, VAULT, "8 emitter");

        // 9: EscrowDebited (token)
        assertEq(logs[9].topics[0], T_EscrowDebited, "9 topic");
        assertEq(logs[9].emitter, TOKEN, "9 emitter");

        // Value spot-checks
        uint256 mintedAmt = abi.decode(logs[0].data, (uint256));
        assertEq(mintedAmt, mintAmt, "mint amount");

        uint256 redeemedAmt = abi.decode(logs[6].data, (uint256));
        assertEq(redeemedAmt, redeemAmt, "redeem amount");

        uint256 debitedAmt = abi.decode(logs[9].data, (uint256));
        assertEq(debitedAmt, slashAmt, "debit amount");
    }
}