// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";

interface IVaultWrBTC {
    function onWrap(address user, uint256 amount) external;
}

interface IRBTCToken {
    function freeBalanceOf(address u) external view returns (uint256);
    function escrowOf(address u) external view returns (uint256);
    function totalBackedOf(address u) external view returns (uint256);
    function mintFromOracle(address to, uint256 amount) external;
    function burnFromOracle(address from, uint256 amount) external;
    function debitEscrowFromOracle(address user, uint256 amount) external;
}

contract rBTCSYNTH is IRBTCToken, ReentrancyGuard {
    // ---- ERC20 metadata ----
    string public constant name   = "Reserve BTC (Soulbound)";
    string public constant symbol = "rBTC-SYNTH";
    uint8  public constant decimals = 8;

    // ---- roles/links ----
    address public immutable oracle;
    address public vault;
    bool    public vaultFrozen;

    // ---- balances ----
    mapping(address => uint256) private _free;
    mapping(address => uint256) private _escrow;

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
    function freeBalanceOf(address u) public view override returns (uint256) { return _free[u]; }
    function escrowOf(address u) public view override returns (uint256) { return _escrow[u]; }
    function totalBackedOf(address u) public view override returns (uint256) { return _free[u] + _escrow[u]; }
    function totalSupply() external pure returns (uint256) { return 0; }

    // ---- one-shot vault setup (via oracle) ----
    function setVault(address v) external onlyOracle {
        if (vault != address(0) || vaultFrozen) revert VaultAlreadySet();
        require(v != address(0), "vault=0");
        vault = v;
        emit VaultSet(v);
    }

    function freezeVaultAddress() external onlyOracle {
        vaultFrozen = true;
    }

    // ---- soulbound wrap/unwrap ----
    function wrap(uint256 amount) external nonReentrant {
        if (vault == address(0)) revert VaultNotSet();
        require(amount > 0, "amount=0");
        if (_free[msg.sender] < amount) revert InsufficientFree();

        _free[msg.sender]   -= amount; // effects
        _escrow[msg.sender] += amount;

        IVaultWrBTC(vault).onWrap(msg.sender, amount); // interaction
        emit Wrapped(msg.sender, amount);
    }

    function unwrapFromVault(address to, uint256 amount) external onlyVault nonReentrant {
        if (_escrow[to] < amount) revert InsufficientEscrow();
        _escrow[to] -= amount;
        _free[to]   += amount;
        emit Unwrapped(to, amount);
    }

    // ---- oracle-only ----
    function mintFromOracle(address to, uint256 amount) external onlyOracle {
        _free[to] += amount;
        emit Minted(to, amount);
    }

    function burnFromOracle(address from, uint256 amount) external onlyOracle {
        if (_free[from] < amount) revert InsufficientFree();
        _free[from] -= amount;
        emit Burned(from, amount);
    }

    function debitEscrowFromOracle(address user, uint256 amount) external onlyOracle {
        if (_escrow[user] < amount) revert InsufficientEscrow();
        _escrow[user] -= amount;
        emit EscrowDebited(user, amount);
    }

    // ---- disable ERC20 transfers ----
    function transfer(address, uint256) external pure returns (bool) { revert TransfersDisabled(); }
    function approve(address, uint256)  external pure returns (bool) { revert TransfersDisabled(); }
    function transferFrom(address, address, uint256) external pure returns (bool) { revert TransfersDisabled(); }
    function allowance(address, address) external pure returns (uint256) { return 0; }
}