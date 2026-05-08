#!/usr/bin/env bash
# Requires bash. On Windows, run under Git Bash / mingw64.
set -euo pipefail

LABELS=(
  "autonomous-safe|0E8A16|Code-only follow-up; eligible for autonomous pickup"
  "design-input-needed|D93F0B|Requires user judgment before work proceeds"
)

# Fetch the repo list separately so a producer failure aborts the script
# rather than silently producing zero-iteration "success."
repos=$(gh repo list TimSimpsonJr --limit 1000 --json nameWithOwner --jq '.[].nameWithOwner') \
  || { echo "ERROR: gh repo list failed. Check gh auth + network." >&2; exit 2; }

if [ -z "$repos" ]; then
  echo "ERROR: gh repo list returned no repos. Aborting before iteration." >&2
  exit 3
fi

failures=0

while read -r repo; do
  for entry in "${LABELS[@]}"; do
    IFS='|' read -r name color desc <<< "$entry"
    if out=$(gh label create "$name" --repo "$repo" --color "$color" --description "$desc" 2>&1); then
      echo "OK:   $repo/$name"
    elif echo "$out" | grep -qi "already exists"; then
      : # idempotent skip; no log
    else
      echo "FAIL: $repo/$name → $out" >&2
      failures=$((failures + 1))
    fi
  done
done <<< "$repos"

if [ $failures -gt 0 ]; then
  echo "ERROR: $failures label-create failure(s). See stderr above." >&2
  exit 4
fi
