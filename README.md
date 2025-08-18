[![Build Status](https://github.com/reservebtc/contracts/actions/workflows/forge.yml/badge.svg)](https://github.com/reservebtc/contracts/actions/workflows/forge.yml)
[![Coverage Status](https://img.shields.io/badge/coverage-lcov-green)](./lcov.info)
![Forge Tests](https://github.com/reservebtc/contracts/actions/workflows/forge.yml/badge.svg)
[![CI – test/security-edges](https://github.com/reservebtc/contracts/actions/workflows/forge.yml/badge.svg?branch=test/security-edges)](https://github.com/reservebtc/contracts/actions/workflows/forge.yml?query=branch%3Atest%2Fsecurity-edges)
[![Oracle Tests](https://github.com/reservebtc/contracts/actions/workflows/oracle-tests.yml/badge.svg)](https://github.com/reservebtc/contracts/actions/workflows/oracle-tests.yml)
[![Forge Invariants](https://github.com/reservebtc/contracts/actions/workflows/forge-invariant.yml/badge.svg)](https://github.com/reservebtc/contracts/actions/workflows/forge-invariant.yml)
[![Invariants (all)](https://github.com/reservebtc/contracts/actions/workflows/invariants.yml/badge.svg)](https://github.com/reservebtc/contracts/actions/workflows/invariants.yml)
[![Token Tests](https://github.com/reservebtc/contracts/actions/workflows/token-tests.yml/badge.svg)](https://github.com/reservebtc/contracts/actions/workflows/token-tests.yml)
[![Vault tests](https://github.com/reservebtc/contracts/actions/workflows/vault-tests.yml/badge.svg)](https://github.com/reservebtc/contracts/actions/workflows/vault-tests.yml)
[![Gas Report](https://github.com/reservebtc/contracts/actions/workflows/gas-report.yml/badge.svg)](https://github.com/reservebtc/contracts/actions/workflows/gas-report.yml)
[![MegaETH Integration Tests](https://github.com/reservebtc/contracts/actions/workflows/megaeth-tests.yml/badge.svg)](https://github.com/reservebtc/contracts/actions/workflows/megaeth-tests.yml)
[![Foundry Tests](https://github.com/reservebtc/contracts/actions/workflows/oracle-resilience-tests.yml/badge.svg)](https://github.com/reservebtc/contracts/actions/workflows/oracle-resilience-tests.yml)
[![Oracle Bounds Tests](https://github.com/reservebtc/contracts/actions/workflows/oracle-bounds-tests.yml/badge.svg)](https://github.com/reservebtc/contracts/actions/workflows/oracle-bounds-tests.yml)
[![Oracle Access-Control Tests](https://github.com/reservebtc/contracts/actions/workflows/oracle-access-control-tests.yml/badge.svg)](https://github.com/reservebtc/contracts/actions/workflows/oracle-access-control-tests.yml)
[![Oracle Events Source-of-Truth](https://github.com/reservebtc/contracts/actions/workflows/oracle-events-source-of-truth.yml/badge.svg?branch=main)](https://github.com/reservebtc/contracts/actions/workflows/oracle-events-source-of-truth.yml)


# ReserveBTC Contracts

This repository contains the core smart contracts for the **ReserveBTC** system:

* **rBTC-SYNTH** — a non-transferable ERC20-like token (soulbound) representing a user's verified BTC reserve (denominated in satoshis).
* **VaultWrBTC** — a transferable ERC20 wrapper ("wrBTC"). Users can deposit rBTC-SYNTH (moves to escrow) and receive transferable wrBTC; redeeming burns wrBTC and releases rBTC-SYNTH back to free balance.
* **rBTCOracle** — the coordinator contract that synchronizes each user's confirmed BTC total (in satoshis). It mints/burns rBTC-SYNTH and, if needed, slashes wrBTC in the vault and debits escrow to maintain 1:1 backing with the verified BTC reserve. It also exposes read-only proofs (Merkle binding and totals) for integrators.

---

## Build (Foundry)

```bash
forge install         # install dependencies
forge build           # compile contracts
forge test            # run tests
```

> Ensure `remappings.txt` and `foundry.toml` are configured if adding external libraries.

---

## Deployment Order (Example)

1. **Deploy `rBTCSYNTH(oracleAddress)`**

   * Temporarily set `oracleAddress = your EOA` (Externally Owned Account) for initial setup.

2. **Deploy `VaultWrBTC(rBTCSYNTH, rBTCOracle)`**

   * Can point to a temporary oracle address initially, then replace with the real oracle.

3. **Deploy `rBTCOracle(rBTCSYNTH, VaultWrBTC, MERKLE_ROOT)`**

   * `MERKLE_ROOT` commits to bindings: `leaf = keccak(user, keccak(btcAddressBytes))`.

4. **Link the vault in the token**

   * From the oracle address:

     ```solidity
     rBTCSYNTH.setVault(VaultWrBTC);
     rBTCSYNTH.freezeVaultAddress(); // optional, makes vault immutable
     ```

5. **Add operators to the oracle**

   * Operators are addresses allowed to call `syncVerifiedTotal`:

     ```solidity
     rBTCOracle.setOperator(operatorAddress, true);
     ```

6. **Remove temporary oracle authority**

   * Ensure only the deployed `rBTCOracle` remains in control.

---

## Off-Chain Oracle Loop

The off-chain oracle should:

1. Monitor BTC addresses bound to users.
2. Calculate `newTotalSats` for each user.
3. Every \~20 seconds (or custom interval), call:

   ```solidity
   rBTCOracle.syncVerifiedTotal(user, newTotalSats, round);
   ```

   * If `newTotalSats > currentTotal`: mint the difference.
   * If `newTotalSats < currentTotal`: burn from free balance first, then slash wrBTC and debit escrow.
   * `round` is an optional counter for tracking updates.

---

## Merkle Binding (User ↔ BTC Address)

* **Functions**:

  * `merkleRoot()` — returns the current root.
  * `verifyBinding(user, btcAddressBytes, proof)` — verifies user/address binding.
* **Leaf format**: `keccak(user, keccak(btcAddressBytes))`.
* Update via `setMerkleRoot(root)` (owner only).

---

## Integrator Read-Only Checks

Integrators can query:

* From `rBTCOracle`:

  * `verifiedTotalSats(user)` — total confirmed reserve.
  * `isBacked(user)` — ensures rBTC equals confirmed total.
  * `verifyBinding(...)` — verifies BTC binding.

* From `rBTCSYNTH`:

  * `freeBalanceOf(user)` — free balance.
  * `escrowOf(user)` — escrowed balance.
  * `totalBackedOf(user)` — total balance (free + escrow).

Example adapter:

```solidity
function _assertBacked(address user, IReserveProofOracle oracle) internal view {
    require(oracle.isBacked(user), "Reserve mismatch");
}
```

---

## Wrapping Flow

* **Wrap**: `rBTCSYNTH.wrap(amount)` → moves `amount` from free to escrow → vault mints `wrBTC`.
* **Redeem**: `VaultWrBTC.redeem(amount)` → burns `wrBTC` → vault calls `unwrapFromVault` to return rBTC-SYNTH to free balance.

If reserves drop:

* Oracle slashes wrBTC via `slashFromOracle`.
* Oracle debits escrow via `debitEscrowFromOracle`.

---

## Token Details & Roles

* **Decimals**: 8 (satoshis)
* **Roles**:

  * `owner` — manages operators and Merkle root.
  * `operator` — allowed to sync totals.

---

## Gas Snapshot

| Contract    | Function               | Avg Gas |
|-------------|-----------------------|---------|
| rBTCSYNTH   | wrap                   | 103985  |
| rBTCSYNTH   | redeem (via Vault)     | 42087   |
| rBTCSYNTH   | mintFromOracle         | 43217   |
| VaultWrBTC  | redeem                 | 42087   |

---

## Testing Recommendations

Test cases should include:

* Minting when `newTotalSats` is higher.
* Burning when free balance covers.
* Burning + slashing when free balance is insufficient.
* Wrapping and redeeming flows.
* Merkle proof verification.
* Soulbound invariants on rBTC-SYNTH.
