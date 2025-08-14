// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";

interface IRBTCSynth {
    function unwrapFromVault(address to, uint256 amount) external; // onlyVault
}

interface IVaultWrBTC {
    function onWrap(address user, uint256 amount) external;
    function slashFromOracle(address user, uint256 amount) external;
}

contract VaultWrBTC is IVaultWrBTC, ReentrancyGuard {
    // --- ERC20 metadata ---
    string public constant name = "Wrapped Reserve BTC";
    string public constant symbol = "wrBTC";
    uint8  public constant decimals = 8;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // --- linked contracts & roles ---
    address public immutable rbtc;   // rBTC-SYNTH
    address public immutable oracle; // rBTCOracle

    // --- events ---
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event Wrapped(address indexed user, uint256 amount);
    event Redeemed(address indexed user, uint256 amount);
    event Slashed(address indexed user, uint256 amount);

    // --- errors ---
    error OnlyToken();
    error OnlyOracle();
    error InsufficientBalance();
    error InsufficientAllowance();

    // --- modifiers ---
    modifier onlyToken() {
        if (msg.sender != rbtc) revert OnlyToken();
        _;
    }

    modifier onlyOracle() {
        if (msg.sender != oracle) revert OnlyOracle();
        _;
    }

    constructor(address _rbtc, address _oracle) {
        require(_rbtc != address(0) && _oracle != address(0), "zero");
        rbtc = _rbtc;
        oracle = _oracle;
    }

    // ---- mint triggered by rBTC.wrap() ----
    function onWrap(address user, uint256 amount) external onlyToken {
        totalSupply += amount;
        balanceOf[user] += amount;
        emit Transfer(address(0), user, amount);
        emit Wrapped(user, amount);
    }

    // ---- regular redemption ----
    function redeem(uint256 amount) external nonReentrant {
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();
        _burn(msg.sender, amount);
        IRBTCSynth(rbtc).unwrapFromVault(msg.sender, amount);
        emit Redeemed(msg.sender, amount);
    }

    // ---- forced slash by oracle ----
    function slashFromOracle(address user, uint256 amount) external onlyOracle {
        if (balanceOf[user] < amount) revert InsufficientBalance();
        _burn(user, amount);
        emit Slashed(user, amount);
    }

    // ---- ERC20 ----
    function transfer(address to, uint256 amount) external returns (bool) {
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();
        _move(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowedAmount = allowance[from][msg.sender];
        if (allowedAmount < amount) revert InsufficientAllowance();
        if (balanceOf[from] < amount) revert InsufficientBalance();
        if (allowedAmount != type(uint256).max) allowance[from][msg.sender] = allowedAmount - amount;
        _move(from, to, amount);
        return true;
    }

    // ---- internals ----
    function _move(address from, address to, uint256 amount) internal {
        unchecked {
            balanceOf[from] -= amount;
            balanceOf[to]   += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        unchecked {
            balanceOf[from] -= amount;
            totalSupply     -= amount;
        }
        emit Transfer(from, address(0), amount);
    }
}