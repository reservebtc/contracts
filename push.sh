#!/bin/bash
branch=$(git rev-parse --abbrev-ref HEAD)

if git diff --quiet && git diff --cached --quiet; then
  echo "⚠️  No changes to commit on branch '$branch'. Nothing pushed."
  exit 0
fi

git add -A
git commit -m "auto commit on branch '$branch' at $(date '+%Y-%m-%d %H:%M:%S')"
git push origin "$branch"