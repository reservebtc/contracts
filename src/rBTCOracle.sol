// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "./IReserveProofOracle.sol";
import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";

interface IRBTCToken {
    // Read-only balances (denominated in sats)
    function freeBalanceOf(address u) external view returns (uint256);
    function escrowOf(address u) external view returns (uint256);
    function totalBackedOf(address u) external view returns (uint256);

    // Oracle-only state changers
    function mintFromOracle(address to, uint256 amount) external;
    function burnFromOracle(address from, uint256 amount) external;
    function debitEscrowFromOracle(address user, uint256 amount) external;
}

interface IWrVault {
    // Oracle-only forced burn of wrBTC (reserve shortfall)
    function slashFromOracle(address user, uint256 amount) external;
}

/// @dev Minimal MerkleProof implementation (OpenZeppelin-compatible order).
library MerkleProof {
    function verify(bytes32[] memory proof, bytes32 root, bytes32 leaf) internal pure returns (bool ok) {
        bytes32 computed = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 p = proof[i];
            computed =
                (computed <= p) ? keccak256(abi.encodePacked(computed, p)) : keccak256(abi.encodePacked(p, computed));
        }
        return computed == root;
    }
}

/**
 * @title rBTCOracle
 * @notice Oracle coordinator for the rBTC-SYNTH system.
 *         - Synchronizes the confirmed BTC reserve (in sats) per user.
 *         - Mints/burns rBTC-SYNTH and, if needed, slashes wrBTC in the Vault.
 *         - Exposes read-only proofs and binding checks for integrators.
 */
contract rBTCOracle is IReserveProofOracle, ReentrancyGuard {
    // ---- linked contracts ----
    IRBTCToken public immutable rbtc; // rBTC-SYNTH token
    IWrVault public immutable vault;  // wrBTC vault

    // ---- operators/admin ----
    address public owner;
    mapping(address => bool) public isOperator;

    // ---- integrator-facing state ----
    bytes32 public override merkleRoot;                       // binding user ↔ btcAddr
    mapping(address => uint64) public override lastVerifiedRound; // optional round index

    // ---- events ----
    event OwnerChanged(address indexed newOwner);
    event OperatorSet(address indexed op, bool enabled);
    event MerkleRootUpdated(bytes32 root);

    // ---- errors ----
    error OnlyOwner();
    error OnlyOperator();

    // ---- modifiers ----
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

    // ---------------- Admin ----------------

    /// @notice Transfer ownership.
    function setOwner(address n) external onlyOwner {
        require(n != address(0), "owner=0"); // zero-address check (Slither)
        owner = n;
        emit OwnerChanged(n);
    }

    /// @notice Grant/revoke operator permissions.
    function setOperator(address op, bool on) external onlyOwner {
        isOperator[op] = on;
        emit OperatorSet(op, on);
    }

    /// @notice Update Merkle root for user ↔ btcAddr binding verification.
    function setMerkleRoot(bytes32 root) external onlyOwner {
        merkleRoot = root;
        emit MerkleRootUpdated(root);
    }

    // --------------- IReserveProofOracle (view) ---------------

    /// @inheritdoc IReserveProofOracle
    function verifiedTotalSats(address user) public view override returns (uint256) {
        // Invariant for integrators: equals free + escrow tracked by rBTC-SYNTH.
        return rbtc.totalBackedOf(user);
    }

    /// @inheritdoc IReserveProofOracle
    function verifyBinding(address user, bytes calldata btcAddressBytes, bytes32[] calldata proof)
        public
        view
        override
        returns (bool)
    {
        // leaf = keccak(user, keccak(btcAddressBytes))
        bytes32 leaf = keccak256(abi.encode(user, keccak256(btcAddressBytes)));
        return MerkleProof.verify(proof, merkleRoot, leaf);
    }

    /// @inheritdoc IReserveProofOracle
    function isBacked(address user) external view override returns (bool) {
        // Fast 1:1 check: exposed for DeFi to assert rBTC equals confirmed reserve.
        return verifiedTotalSats(user) == rbtc.totalBackedOf(user);
    }

    // ---------------- Main synchronization entrypoint ----------------

    /**
     * @notice Synchronize user's confirmed BTC total (in sats).
     * @dev If newTotalSats > current -> mint the delta to user's free balance.
     *      If newTotalSats < current -> burn from free first, then
     *      force-burn wrBTC in the Vault and debit escrow for the remainder.
     *      Uses a reentrancy guard and updates round (if provided) before external calls.
     * @param user The user to sync.
     * @param newTotalSats Confirmed BTC total (free + escrow) in sats.
     * @param round Optional monitoring round/cycle number (0 to skip).
     */
    function syncVerifiedTotal(address user, uint256 newTotalSats, uint64 round)
        external
        onlyOperatorM
        nonReentrant
    {
        // Effects: update round first (monotonic non-decreasing, ignore 0)
        if (round != 0) {
            uint64 prev = lastVerifiedRound[user];
            if (round > prev) lastVerifiedRound[user] = round;
        }

        uint256 curTotal = rbtc.totalBackedOf(user);

        if (newTotalSats > curTotal) {
            // Mint delta into free balance
            rbtc.mintFromOracle(user, newTotalSats - curTotal);
        } else if (newTotalSats < curTotal) {
            uint256 toBurn = curTotal - newTotalSats;

            // 1) Burn from free balance first
            uint256 free = rbtc.freeBalanceOf(user);
            uint256 burnFree = free >= toBurn ? toBurn : free;
            if (burnFree > 0) {
                rbtc.burnFromOracle(user, burnFree);
                toBurn -= burnFree;
            }

            // 2) If still needed, slash wrBTC in the Vault and debit escrow
            if (toBurn > 0) {
                vault.slashFromOracle(user, toBurn);        // burns wrBTC
                rbtc.debitEscrowFromOracle(user, toBurn);    // decreases escrow
            }
        }
    }
}