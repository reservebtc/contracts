// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "./IReserveProofOracle.sol";

interface IRBTCToken {
    function freeBalanceOf(address u) external view returns (uint256);
    function escrowOf(address u) external view returns (uint256);
    function totalBackedOf(address u) external view returns (uint256);

    function mintFromOracle(address to, uint256 amount) external;
    function burnFromOracle(address from, uint256 amount) external;
    function debitEscrowFromOracle(address user, uint256 amount) external;
}

interface IWrVault {
    function slashFromOracle(address user, uint256 amount) external;
}

library MerkleProof {
    function verify(bytes32[] memory proof, bytes32 root, bytes32 leaf) internal pure returns (bool ok) {
        bytes32 computed = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 p = proof[i];
            computed = (computed <= p)
                ? keccak256(abi.encodePacked(computed, p))
                : keccak256(abi.encodePacked(p, computed));
        }
        return computed == root;
    }
}

contract rBTCOracle is IReserveProofOracle {
    IRBTCToken public immutable rbtc;
    IWrVault   public immutable vault;

    address public owner;
    mapping(address => bool) public isOperator;

    bytes32 public override merkleRoot;
    mapping(address => uint64) public override lastVerifiedRound;

    event OwnerChanged(address indexed newOwner);
    event OperatorSet(address indexed op, bool enabled);
    event MerkleRootUpdated(bytes32 root);

    error OnlyOwner();
    error OnlyOperator();

    // --- return this modifier if it is missing ---
    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier onlyOperatorM() {
        if (!isOperator[msg.sender]) revert OnlyOperator();
        _;
    }

    constructor(address _rbtc, address _vault, bytes32 _root) {
        require(_rbtc != address(0) && _vault != address(0), "zero");
        rbtc = IRBTCToken(_rbtc);
        vault = IWrVault(_vault);

        owner = msg.sender;
        isOperator[msg.sender] = true;

        if (_root != bytes32(0)) {
            merkleRoot = _root;
            emit MerkleRootUpdated(_root);
        }

        emit OwnerChanged(msg.sender);
        emit OperatorSet(msg.sender, true);
    }

    // -------- Admin --------

    function setOwner(address n) external onlyOwner {
        address old = owner;
        owner = n;

        // revoke operator from old owner (if was set)
        if (old != address(0) && isOperator[old]) {
            isOperator[old] = false;
            emit OperatorSet(old, false);
        }

        // grant operator to new owner (if non-zero)
        if (n != address(0) && !isOperator[n]) {
            isOperator[n] = true;
            emit OperatorSet(n, true);
        }

        emit OwnerChanged(n);
    }

    function setOperator(address op, bool on) external onlyOwner {
        isOperator[op] = on;
        emit OperatorSet(op, on);
    }

    function setMerkleRoot(bytes32 root) external onlyOwner {
        merkleRoot = root;
        emit MerkleRootUpdated(root);
    }

    // -------- Views --------

    function verifiedTotalSats(address user) public view override returns (uint256) {
        return rbtc.totalBackedOf(user);
    }

    function verifyBinding(address user, bytes calldata btcAddressBytes, bytes32[] calldata proof)
        public
        view
        override
        returns (bool)
    {
        bytes32 leaf = keccak256(abi.encode(user, keccak256(btcAddressBytes)));
        return MerkleProof.verify(proof, merkleRoot, leaf);
    }

    function isBacked(address user) external view override returns (bool) {
        return verifiedTotalSats(user) == rbtc.totalBackedOf(user);
    }

    // -------- Sync --------

    function syncVerifiedTotal(address user, uint256 newTotalSats, uint64 round) external onlyOperatorM {
        uint256 curTotal = rbtc.totalBackedOf(user);

        if (newTotalSats > curTotal) {
            rbtc.mintFromOracle(user, newTotalSats - curTotal);
        } else if (newTotalSats < curTotal) {
            uint256 toBurn = curTotal - newTotalSats;

            uint256 free = rbtc.freeBalanceOf(user);
            uint256 burnFree = free >= toBurn ? toBurn : free;
            if (burnFree > 0) {
                rbtc.burnFromOracle(user, burnFree);
                toBurn -= burnFree;
            }

            if (toBurn > 0) {
                vault.slashFromOracle(user, toBurn);
                rbtc.debitEscrowFromOracle(user, toBurn);
            }
        }

        if (round != 0) lastVerifiedRound[user] = round;
    }
}