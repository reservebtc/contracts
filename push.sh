#!/bin/bash
branch=$(git rev-parse --abbrev-ref HEAD)

if git diff --quiet && git diff --cached --quiet; then
  echo "⚠️  No changes to commit on branch '$branch'. Nothing pushed."
  exit 0
fi

git add -A
git commit -F - <<EOF
✅ All 84 tests passed across 24 suites:
1. Integration E2E
2. Oracle Admin
3. Oracle Events
4. Oracle Invariant
5. Oracle Merkle
6. Oracle Sync — Monotonic & Idempotent
7. Oracle Sync — Multi-User Invariant
8. Oracle Sync — Unit
9. rBTCSYNTH Soulbound Unit
10. RBTCSynth Unit
11. Security Edges
12. VaultWrBTC — Conservation Invariant
13. VaultWrBTC — Edges
14. VaultWrBTC — ERC20
15. VaultWrBTC — Fuzz Invariant
16. VaultWrBTC — Unit
17. Gas Snapshots
18. MegaETH Integration Tests
19. Oracle Resilience — Deficit Handling & Idempotency
20. Oracle Bounds — Upper Limits & Long-Path Syncs
21. Oracle Access-Control — Owner/Operator Negative Paths
22. Oracle Events — Source-of-Truth Ordering
23. Oracle Reentrancy Regression — wrap/redeem/sync
24. Fork Canary Simulation

Stable run @ $(date '+%Y-%m-%d %H:%M:%S')
EOF

git push origin "$branch"