#!/usr/bin/env bash
# The spike round three more times: 100 users, 3000 for 80 s, 100 again.
set -euo pipefail
cd "$(dirname "$0")"
for i in 2 3 4; do ORDERS=5000000 ./batch-users.sh spike-$i 0.2 100,3000,100 80; done
echo BATCH DONE
