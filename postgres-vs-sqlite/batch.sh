#!/usr/bin/env bash
# Every round of the episode. Each family runs three times, interleaved, so a slow hour hits all families alike.
cd "$(dirname "$0")"
r() { echo "=== $1  $(date +%T)"; ./round.sh "$@" 2>&1 | sed -n '/^postgres$/,$p' | grep -E "^(postgres|sqlite)$|^sustained"; }
for n in 1 2 3; do
  r read-$n   0    1000 1000 20 30s
  r write-$n  1    100  100  25 30s
  r shop5-$n  0.05 500  500  24 30s
  r shop20-$n 0.2  250  250  24 30s
done
for n in 1 2 3; do
  LITE_WRITERS=1 r write-1w-$n  1   100 100 25 30s
  LITE_WRITERS=1 r shop20-1w-$n 0.2 250 250 24 30s
done
SWAP=1 LITE_WRITERS=1 r shop20-1w-swap 0.2 250 250 24 30s
SWAP=1 r read-swap 0 1000 1000 20 30s
PG_POOL=10 r write-pgpool10 1 100 100 25 30s
echo "=== done $(date +%T)"
