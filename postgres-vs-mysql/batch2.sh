#!/usr/bin/env bash
# Repeats for the medians, the host check, MySQL without performance_schema, then long runs. Run with: bash batch2.sh
cd "$(dirname "$0")"
for n in 2 3; do
./round.sh read-$n   read   2000 1000 14 30s
./round.sh insert-$n insert 200  200  14 30s
./round.sh shop5-$n  shop5  1000 1000 14 30s
./round.sh shop20-$n shop20 1000 750  14 30s
./round.sh views-$n  views  1000 1000 14 30s
./round.sh status-$n status 500  500  14 30s
done
./round.sh insert-1b insert 200  200  14 30s
./round.sh shop20-1b shop20 1000 750  14 30s
SWAP=1 ./round.sh read-swap   read   2000 1000 14 30s
SWAP=1 ./round.sh views-swap  views  1000 1000 14 30s
MY_PFS_OFF=1 ./round.sh read-nopfs  read  2000 1000 14 30s
MY_PFS_OFF=1 ./round.sh views-nopfs views 1000 1000 14 30s
./round.sh read-20m read 1000 1000 14 30s 20000000
./round.sh soak-status status 2000 1 1 1800s
LONG_TX=1700 ./round.sh longtx-status status 2000 1 1 1500s
