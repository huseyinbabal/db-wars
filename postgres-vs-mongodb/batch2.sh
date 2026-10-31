#!/usr/bin/env bash
# The measured rounds, in order. Each round starts from freshly loaded data on both stacks.
set -uo pipefail
cd "$(dirname "$0")"
r() { echo "=== $1  $(date +%T)"; ./round.sh "$@" 2>&1 | sed -n '/^postgres$/,$p'; }
# r read-1    read   3 1000 1000 12 30s
r insert-1  insert 3  500  500 12 30s
r update-1  update 3 1000 1000 12 30s
r shop-1    shop   3  400  400 12 30s
PG_TUNE="ALTER INDEX orders_items SET (fastupdate = off)" r shop-tuned-1 shop 3 400 400 12 30s
r bigdoc-update-1 update 40 500 500 12 30s 250000
r bigdoc-read-1   read   40 500 500 12 30s 250000
echo "=== done $(date +%T)"
