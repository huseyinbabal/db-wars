#!/usr/bin/env bash
# First pass: every round once, to find each side's range.
cd "$(dirname "$0")"
./round.sh read-1   read   2000 1000 14 30s
./round.sh insert-1 insert 500  500  14 30s
./round.sh shop5-1  shop5  1000 1000 14 30s
./round.sh shop20-1 shop20 500  500  14 30s
./round.sh views-1  views  1000 1000 14 30s
./round.sh status-1 status 500  500  14 30s
