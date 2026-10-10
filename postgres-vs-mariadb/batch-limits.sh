#!/usr/bin/env bash
# The full suite: every round on both databases, each run from freshly loaded data.
cd "$(dirname "$0")"
U=100,200,400,800,1600,3200
ORDERS=5000000  ./batch-users.sh read-2  0.05 $U 80
ORDERS=5000000  ./batch-users.sh write-2 0.5  $U 80
ORDERS=5000000  ./batch-users.sh read-3  0.05 $U 80
ORDERS=5000000  ./batch-users.sh write-3 0.5  $U 80
# data larger than memory: 20 million orders on a 4 GiB machine
ORDERS=20000000 ./batch-users.sh big     0.05 $U 80
# no connection pool: every request opens and closes its own database connection
ORDERS=5000000 DB_POOL_MODE=off ./batch-users.sh nopool 0.05 100,200,400,800,1600 80
# sudden spike and recovery: 100 users, then 3000 for a minute and a half, then 100 again
ORDERS=5000000  ./batch-users.sh spike   0.2  100,3000,100 80
echo BATCH DONE
