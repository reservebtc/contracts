#!/bin/bash
branch=$(git rev-parse --abbrev-ref HEAD)

if git diff --quiet && git diff --cached --quiet; then
  echo "⚠️  No changes to commit on branch '$branch'. Nothing pushed."
  exit 0
fi

git add -A

# Многострочный коммит-месседж (разово — можно редактировать по месту)
git commit -F - <<'COMMITMSG'
chore(megaeth): deploy rBTCOracle/rBTCSYNTH/VaultWrBTC + on-chain smoke (sync→wrap→redeem)

- Oracle:  0xFB9945fc9FFCca96aF0eBEe359e5C6e9dA7af83a
- Token:   0x56a421E2A8721D579C8D82572bF1d695A239A8b6
- Vault:   0x1eDed1Be152b0DD6F9Fb1A84a1f778f2c8Ef6cDe
- Operator enabled: 0xea8fFEe94Da08f65765EC2A095e9931FD03e6c1b
- Merkle root: 0x0000000000000000000000000000000000000000000000000000000000000000

Smoke E2E:
- syncVerifiedTotal(USER, 1000, 1) ✔
- wrap(600) ✔
- redeem(500) ✔

Invariants held:
- wr.totalSupply == Σ escrow
- wr.balanceOf(u) == escrowOf(u)
- free + escrow == totalBacked
COMMITMSG

git push origin "$branch"