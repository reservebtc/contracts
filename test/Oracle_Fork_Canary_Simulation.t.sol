// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

// Foundry
import "forge-std/Test.sol";

// Project contracts / interfaces
import {rBTCOracle, IRBTCToken} from "../src/rBTCOracle.sol";
import {VaultWrBTC, IRBTCSynth} from "../src/VaultWrBTC.sol";

/// ---------------------------------------------------------------------------
/// Mock token implementing IRBTCToken + IRBTCSynth surface needed by the tests.
/// It tracks free/escrow balances, supports wrap/unwrap, and exposes oracle-only
/// entrypoints. The oracle address can be bootstrapped once post-deployment to
/// avoid constructor circular dependencies in tests.
/// ---------------------------------------------------------------------------
contract MockRBTCToken is IRBTCToken, IRBTCSynth {
    // --- ERC20-like metadata (not used functionally here) ---
    string public constant name = "Mock rBTC-SYNTH";
    string public constant symbol = "mrBTC";
    uint8  public constant decimals = 8;

    // --- roles/links ---
    address public oracle;               // rBTCOracle address (set once via bootstrapOracle)
    address public vault;                // VaultWrBTC (set by oracle)

    // --- balances ---
    mapping(address => uint256) private _free;   // free balance
    mapping(address => uint256) private _escrow; // escrowed (backing wrBTC)

    // --- events/errors (minimal set for the mock) ---
    event VaultSet(address indexed v);
    event OracleSet(address indexed o);

    error OnlyOracle();
    error OnlyVault();
    error InsufficientFree();
    error InsufficientEscrow();

    modifier onlyOracle() {
        if (msg.sender != oracle || oracle == address(0)) revert OnlyOracle();
        _;
    }
    modifier onlyVault() {
        if (msg.sender != vault || vault == address(0)) revert OnlyVault();
        _;
    }

    /// @notice Allow zero in ctor to break constructor circular dependency in tests.
    constructor(address _oracle) {
        oracle = _oracle; // may be zero; set later via bootstrapOracle()
        if (_oracle != address(0)) emit OracleSet(_oracle);
    }

    /// @notice One-time oracle bootstrap. Anyone may set it iff not set yet.
    function bootstrapOracle(address _oracle) external {
        require(oracle == address(0), "oracle already set");
        require(_oracle != address(0), "oracle=0");
        oracle = _oracle;
        emit OracleSet(_oracle);
    }

    // ---- IRBTCToken (views) ----
    function freeBalanceOf(address u) external view returns (uint256) { return _free[u]; }
    function escrowOf(address u) external view returns (uint256) { return _escrow[u]; }
    function totalBackedOf(address u) public view returns (uint256) { return _free[u] + _escrow[u]; }

    // ---- Oracle-only state changers ----
    function mintFromOracle(address to, uint256 amount) external onlyOracle {
        _free[to] += amount;
    }

    function burnFromOracle(address from, uint256 amount) external onlyOracle {
        if (_free[from] < amount) revert InsufficientFree();
        _free[from] -= amount;
    }

    function debitEscrowFromOracle(address user, uint256 amount) external onlyOracle {
        if (_escrow[user] < amount) revert InsufficientEscrow();
        _escrow[user] -= amount;
    }

    // ---- Vault wiring (oracle-only) ----
    function setVault(address v) external onlyOracle {
        require(vault == address(0), "vault already set");
        require(v != address(0), "vault=0");
        vault = v;
        emit VaultSet(v);
    }

    // ---- User flows (soulbound style) ----
    function wrap(uint256 amount) external {
        if (_free[msg.sender] < amount) revert InsufficientFree();
        _free[msg.sender] -= amount;
        _escrow[msg.sender] += amount;

        // Mint wrBTC via the Vault; Vault will call back unwrapFromVault on redeem.
        VaultWrBTC(vault).onWrap(msg.sender, amount);
    }

    /// @notice Called only by the Vault on redeem; moves escrow -> free.
    function unwrapFromVault(address to, uint256 amount) external onlyVault {
        if (_escrow[to] < amount) revert InsufficientEscrow();
        _escrow[to] -= amount;
        _free[to] += amount;
    }
}

/// ---------------------------------------------------------------------------
/// Fork canary: mint → wrap → sync(+) → sync(-) → redeem with invariants.
/// Works on a public RPC fork (if ETH_RPC_URL is provided) or on local EVM.
/// ---------------------------------------------------------------------------
contract Oracle_Fork_Canary_Simulation is Test {
    // If set, we run on a fork. If empty, we run on local in-memory EVM.
    string constant FORK_ENV = "ETH_RPC_URL";

    // System under test
    rBTCOracle internal oracle;
    MockRBTCToken internal token;
    VaultWrBTC internal vault;

    // Test actor
    address internal user = address(0xBEEF);

    function setUp() public {
        // Optional fork
        string memory rpc = vm.envOr(FORK_ENV, string(""));
        if (bytes(rpc).length != 0) {
            vm.createSelectFork(rpc);
        }

        // Deploy mock token with oracle unset (zero); will be bootstrapped later
        token = new MockRBTCToken(address(0));

        // Deploy real vault. Its `oracle` is only used for slashFromOracle; we
        // do not trigger slashing in this canary, so we can pass a dummy oracle.
        // (Redeem/wrap paths do not depend on this address.)
        vault = new VaultWrBTC(address(token), address(this)); // dummy oracle

        // Deploy the real oracle against our token & vault
        oracle = new rBTCOracle(address(token), address(vault), bytes32(0));
        // The deploying address (this test) is owner & operator by default.

        // Bootstrap token's oracle address to the real oracle we just deployed
        token.bootstrapOracle(address(oracle));

        // Wire token -> vault from the oracle address (onlyOracle)
        vm.prank(address(oracle));
        token.setVault(address(vault));

        // Small realism tweaks
        vm.fee(100 gwei);
        vm.warp(block.timestamp + 12);
    }

    /// @notice End-to-end canary scenario with invariants kept intact.
    function test_Fork_Canary_Scenario() public {
        // --- Initial assertions ---
        assertEq(vault.totalSupply(), 0, "vault totalSupply should start at 0");
        assertEq(token.freeBalanceOf(user), 0, "user free should start at 0");
        assertEq(token.escrowOf(user), 0, "user escrow should start at 0");

        // --- Step 1: positive sync mints to free (curTotal=0 -> newTotal=1_000_000) ---
        uint256 initialTotal = 1_000_000; // sats
        // msg.sender must be an operator => the test (owner) is operator by ctor
        oracle.syncVerifiedTotal(user, initialTotal, 1);

        assertEq(token.freeBalanceOf(user), initialTotal, "free after initial positive sync");
        assertEq(token.escrowOf(user), 0, "escrow after initial positive sync");

        // --- Step 2: user wraps a part into wrBTC (moves free->escrow and mints wrBTC) ---
        uint256 wrapAmount = 400_000;
        vm.prank(user);
        token.wrap(wrapAmount);

        assertEq(token.freeBalanceOf(user), initialTotal - wrapAmount, "free after wrap");
        assertEq(token.escrowOf(user), wrapAmount, "escrow after wrap");
        assertEq(vault.balanceOf(user), wrapAmount, "wrBTC after wrap");
        assertEq(vault.totalSupply(), wrapAmount, "wrBTC supply after wrap");

        // --- Step 3: sync upwards: +200_000 (mint delta to free) ---
        uint256 increasedTotal = initialTotal + 200_000;
        oracle.syncVerifiedTotal(user, increasedTotal, 2);
        assertEq(
            token.freeBalanceOf(user) + token.escrowOf(user),
            increasedTotal,
            "total after positive sync"
        );

        // --- Step 4: sync downwards: -300_000 (burn from free first; no slashing expected) ---
        uint256 decreasedTotal = increasedTotal - 300_000;
        oracle.syncVerifiedTotal(user, decreasedTotal, 3);
        assertEq(
            token.freeBalanceOf(user) + token.escrowOf(user),
            decreasedTotal,
            "total after negative sync"
        );
        // Vault supply must equal escrow
        assertEq(vault.totalSupply(), token.escrowOf(user), "wrBTC supply must match escrow");

        // --- Step 5: redeem 100_000 -> escrow decreases, free increases, supply/balance drop by exactly amount ---
        uint256 redeemAmount = 100_000;
        uint256 tsBefore = vault.totalSupply();

        vm.prank(user);
        vault.redeem(redeemAmount);

        assertEq(vault.totalSupply(), tsBefore - redeemAmount, "wr supply decreased by redeem amount");
        assertEq(vault.balanceOf(user), token.escrowOf(user), "wr balance must equal escrow 1:1");
        assertEq(
            token.freeBalanceOf(user) + token.escrowOf(user),
            decreasedTotal,
            "total backed is conserved through redeem"
        );

        // --- Final sanity: oracle view equals token accounting ---
        assertEq(oracle.verifiedTotalSats(user), token.totalBackedOf(user), "oracle view == token accounting");
    }
}