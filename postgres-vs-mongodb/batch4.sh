#!/usr/bin/env bash
# After batch3 (trimmed for cost): hook footage with the fixed dashboard, one more insert run, what fastupdate = off costs on inserts.
set -uo pipefail
cd "$(dirname "$0")"
r() { echo "=== $1  $(date +%T)"; ./round.sh "$@" 2>&1 | sed -n '/^postgres$/,$p'; }
T="ALTER INDEX orders_items SET (fastupdate = off)"
r shop-rec shop 3 400 400 12 30s   # recorded again with the fixed dashboard (time from round start, gaps stay gaps): hook footage
RECORD=0 r insert-5 insert 3 1000 1000 12 30s   # insert-2 was lost (round.sh edited while it ran)
PG_TUNE="$T" RECORD=0 r insert-tuned-1 insert 3 1000 1000 12 30s
echo "=== done $(date +%T)"
