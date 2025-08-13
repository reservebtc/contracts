// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface IVaultWrBTC {
    function onWrap(address user, uint256 amount) external;
}

contract rBTCSYNTH {
    // ---- ERC20 metadata ----
    string public constant name = "Reserve BTC (Soulbound)";
    string public constant symbol = "rBTC-SYNTH";
    uint8 public constant decimals = 8; // denominated in satoshis

    // ---- roles/links ----
    address public immutable oracle; // address of rBTCOracle
    address public vault; // the only wrapping contract
    bool public vaultFrozen; // can be frozen after initial set

    // ---- balances ----
    mapping(address => uint256) private _free; // free balance (soulbound)
    mapping(address => uint256) private _escrow; // locked in Vault (under wrBTC)

    // ---- events/errors ----
    event Minted(address indexed to, uint256 amount);
    event Burned(address indexed from, uint256 amount);
    event Wrapped(address indexed user, uint256 amount);
    event Unwrapped(address indexed user, uint256 amount);
    event EscrowDebited(address indexed user, uint256 amount);
    event VaultSet(address indexed vault);

    error OnlyOracle();
    error OnlyVault();
    error VaultNotSet();
    error VaultAlreadySet();
    error TransfersDisabled();
    error InsufficientFree();
    error InsufficientEscrow();

    modifier onlyOracle() {
        if (msg.sender != oracle) revert OnlyOracle();
        _;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    constructor(address _oracle) {
        require(_oracle != address(0), "oracle=0");
        oracle = _oracle;
    }

    // ---- view ----
    function freeBalanceOf(address u) public view returns (uint256) {
        return _free[u];
    }

    function escrowOf(address u) public view returns (uint256) {
        return _escrow[u];
    }

    function totalBackedOf(address u) public view returns (uint256) {
        return _free[u] + _escrow[u];
    }

    function totalSupply() external pure returns (uint256 s) {
        // For monitoring purposes: not calculating total supply across all users (gas expensive),
        // could store an aggregate during mint/burn if needed (simplified here).
        return 0;
    }

    // ---- one-shot vault setup (via oracle) ----
    function setVault(address v) external onlyOracle {
        if (vault != address(0) || vaultFrozen) revert VaultAlreadySet();
        require(v != address(0), "vault=0");
        vault = v;
        emit VaultSet(v);
    }

    /// Optionally freeze the vault address to prevent future changes.
    function freezeVaultAddress() external onlyOracle {
        vaultFrozen = true;
    }

    // ---- soulbound wrap/unwrap ----
    function wrap(uint256 amount) external {
        if (vault == address(0)) revert VaultNotSet();
        require(amount > 0, "amount=0"); // <-- added zero-amount guard
        if (_free[msg.sender] < amount) revert InsufficientFree();

        _free[msg.sender] -= amount;
        _escrow[msg.sender] += amount;

        IVaultWrBTC(vault).onWrap(msg.sender, amount);
        emit Wrapped(msg.sender, amount);
    }

    /// Called only by the vault when unwrapping (user burned wrBTC).
    function unwrapFromVault(address to, uint256 amount) external onlyVault {
        if (_escrow[to] < amount) revert InsufficientEscrow();
        _escrow[to] -= amount;
        _free[to] += amount;
        emit Unwrapped(to, amount);
    }

    // ---- oracle-only calls ----
    function mintFromOracle(address to, uint256 amount) external onlyOracle {
        _free[to] += amount;
        emit Minted(to, amount);
    }

    function burnFromOracle(address from, uint256 amount) external onlyOracle {
        if (_free[from] < amount) revert InsufficientFree();
        _free[from] -= amount;
        emit Burned(from, amount);
    }

    /// Deduct from escrow (after forced wrBTC burn in the Vault).
    function debitEscrowFromOracle(address user, uint256 amount) external onlyOracle {
        if (_escrow[user] < amount) revert InsufficientEscrow();
        _escrow[user] -= amount;
        emit EscrowDebited(user, amount);
    }

    // ---- fully disable ERC20 transfers ----
    function transfer(address, uint256) external pure returns (bool) {
        revert TransfersDisabled();
    }

    function approve(address, uint256) external pure returns (bool) {
        revert TransfersDisabled();
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        revert TransfersDisabled();
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }
}