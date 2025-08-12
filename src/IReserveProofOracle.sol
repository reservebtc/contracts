// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @notice Read-only facade for DeFi integrators.
interface IReserveProofOracle {
    /// @notice Merkle root for leaves hashed as keccak(user, keccak(btcAddressBytes)).
    function merkleRoot() external view returns (bytes32);

    /// @notice Current verified total for a user (free + escrow), denominated in satoshis.
    function verifiedTotalSats(address user) external view returns (uint256);

    /// @notice Last verification round/index for the user (0 if unused).
    function lastVerifiedRound(address user) external view returns (uint64);

    /// @notice Verifies user ↔ BTC address binding via a Merkle proof.
    /// @param user EVM address of the user.
    /// @param btcAddressBytes Raw BTC address bytes as provided during verification.
    /// @param merkleProof Merkle proof from leaf to the stored Merkle root.
    /// @return True if the binding is valid.
    function verifyBinding(address user, bytes calldata btcAddressBytes, bytes32[] calldata merkleProof)
        external
        view
        returns (bool);

    /// @notice Quick 1:1 check that issued synthetic equals the verified BTC reserve.
    /// @param user EVM address of the user.
    /// @return True if the account is fully backed 1:1.
    function isBacked(address user) external view returns (bool);
}
