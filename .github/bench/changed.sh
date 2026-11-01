#!/usr/bin/env bash
# Prints the comparison folders this PR touches as a JSON list. A folder takes part once it has ci/bench.env.
# The checkout is GitHub's merge commit, so HEAD^1 is the base branch. A change under .github/ tests them all.
set -euo pipefail
files=$(git diff --name-only HEAD^1 HEAD)
dirs=$(echo "$files" | cut -s -d/ -f1 | sort -u)
if echo "$dirs" | grep -qx .github; then dirs=$(ls -d */ | tr -d /); fi
for d in $dirs; do [ -f "$d/ci/bench.env" ] && echo "$d"; done | python3 -c 'import json, sys; print(json.dumps(sys.stdin.read().split()))'
