#!/usr/bin/env bash
# Second pass: insert with a wider range, every measured round twice more (median of three), and one swapped-host check.
set -uo pipefail
cd "$(dirname "$0")"
r() { echo "=== $1  $(date +%T)"; ./round.sh "$@" 2>&1 | sed -n '/^postgres$/,$p'; }
T="ALTER INDEX orders_items SET (fastupdate = off)"
RECORD=0 r insert-2 insert 3 1000 1000 12 30s
PG_TUNE="$T" r shop-tuned-1b shop 3 500 500 14 30s   # first pass topped out at 4,800 req/s on both sides; recorded for the video
for n in 2 3; do
  RECORD=0 r read-$n   read   3 1000 1000 12 30s
  RECORD=0 r insert-$((n + 1)) insert 3 1000 1000 12 30s
  RECORD=0 r update-$n update 3 1000 1000 12 30s
  RECORD=0 r shop-$n   shop   3  500  500 14 30s
  PG_TUNE="$T" RECORD=0 r shop-tuned-$n shop 3 500 500 14 30s
done
SWAP=1 PG_TUNE="$T" RECORD=0 r shop-tuned-swap shop 3 500 500 14 30s
echo "=== done $(date +%T)"
