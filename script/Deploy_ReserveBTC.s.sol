// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";

// Your contracts
import {rBTCOracle}  from "../src/rBTCOracle.sol";
import {VaultWrBTC}  from "../src/VaultWrBTC.sol";
import {rBTCSYNTH}   from "../src/rBTCSYNTH.sol";

/// @dev Helper to pre-compute the CREATE address for a contract
///      deployed by `deployer` at `nonce` (standard RLP + keccak256).
library CreateAddress {
    function compute(address deployer, uint256 nonce) internal pure returns (address) {
        if (nonce == 0x00) {
            return address(uint160(uint256(keccak256(abi.encodePacked(
                bytes1(0xd6), bytes1(0x94), deployer, bytes1(0x80)
            )))));
        }
        if (nonce <= 0x7f) {
            return address(uint160(uint256(keccak256(abi.encodePacked(
                bytes1(0xd6), bytes1(0x94), deployer, uint8(nonce)
            )))));
        }
        if (nonce <= 0xff) {
            return address(uint160(uint256(keccak256(abi.encodePacked(
                bytes1(0xd7), bytes1(0x94), deployer, bytes1(0x81), uint8(nonce)
            )))));
        }
        if (nonce <= 0xffff) {
            return address(uint160(uint256(keccak256(abi.encodePacked(
                bytes1(0xd8), bytes1(0x94), deployer, bytes1(0x82), bytes2(uint16(nonce))
            )))));
        }
        if (nonce <= 0xffffff) {
            return address(uint160(uint256(keccak256(abi.encodePacked(
                bytes1(0xd9), bytes1(0x94), deployer, bytes1(0x83), bytes3(uint24(nonce))
            )))));
        }
        // nonce up to 0xffffffff is more than sufficient for deployment flows
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xda), bytes1(0x94), deployer, bytes1(0x84), bytes4(uint32(nonce))
        )))));
    }
}

contract DeployReserveBTC is Script {
    function run() external {
        // ====== Environment ======
        // Required: deployer private key (0x-prefixed hex)
        uint256 pk = vm.envUint("DEPLOYER_PK");

        // Optional: operator to be enabled on the Oracle right after deploy
        address operatorAddr = vm.envOr("OPERATOR", address(0));

        // Optional: initial Merkle root (zero by default)
        bytes32 merkleRoot = vm.envOr("MERKLE_ROOT", bytes32(0));

        // Safety check for MegaETH Testnet (chainId = 6342).
        // Set ALLOW_NON_MEGAETH=true to bypass when needed (e.g., local tests).
        bool allowAnyChain = vm.envOr("ALLOW_NON_MEGAETH", false);
        require(block.chainid == 6342 || allowAnyChain, "Wrong chain: expected MegaETH (chainId=6342)");

        address deployer = vm.addr(pk);

        // ====== Predict the future Oracle address ======
        // We will send three consecutive CREATE txs:
        //   1) rBTCSYNTH, 2) VaultWrBTC, 3) rBTCOracle.
        uint256 currentNonce = vm.getNonce(deployer);
        address predictedOracle = CreateAddress.compute(deployer, currentNonce + 2);

        // ====== Broadcast ======
        vm.startBroadcast(pk);

        // (1) Deploy rBTCSYNTH. Pass the predicted Oracle so token ACLs align immediately.
        rBTCSYNTH token = new rBTCSYNTH(predictedOracle);

        // (2) Deploy VaultWrBTC with token + predicted Oracle.
        VaultWrBTC vault = new VaultWrBTC(address(token), predictedOracle);

        // (3) Deploy the actual Oracle with the real token and vault addresses.
        rBTCOracle oracle = new rBTCOracle(address(token), address(vault), merkleRoot);

        // (4) Auto-wire vault -> token via Oracle one-time method (requires rBTCOracle with wireVaultOnce()).
        //     If already wired or not permitted (shouldn't happen right after deploy), we just log and continue.
        try oracle.wireVaultOnce() {
            console2.log("wireVaultOnce() OK");
        } catch {
            console2.log("wireVaultOnce() skipped (already wired or not permitted)");
        }

        // (5) Optionally enable an operator
        if (operatorAddr != address(0)) {
            oracle.setOperator(operatorAddr, true);
            console2.log("Operator enabled:", operatorAddr);
        }

        vm.stopBroadcast();

        // ====== Deployment log ======
        console2.log("-----------------");
        console2.log("Deployer         :", deployer);
        console2.log("rBTCSYNTH        :", address(token));
        console2.log("VaultWrBTC       :", address(vault));
        console2.log("rBTCOracle       :", address(oracle));
        console2.log("Oracle predicted :", predictedOracle);
        console2.log("Prediction match :", address(oracle) == predictedOracle);
        console2.log("-----------------");
    }
}