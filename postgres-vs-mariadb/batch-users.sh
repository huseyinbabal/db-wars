#!/usr/bin/env bash
# One round per database, the two take turns on the same machine, each starts from freshly loaded data.
#   [ORDERS=5000000] [DB_POOL_MODE=off] SSH_CONF=<ssh config> APP=http://<app private ip>:8000 ./batch-users.sh <round name> <writes> <users> <HOLD seconds>
set -euo pipefail
cd "$(dirname "$0")"
ROUND=$1; WRITES=$2; USERS=$3; HOLD=$4
ssh_() { ssh -F "$SSH_CONF" "$@"; }
use() {  # stop both, start one, reload the data
  local unit exporter
  if [ "$1" = postgres ]; then unit=postgresql@18-main; exporter=prometheus-postgres-exporter; else unit=mariadb; exporter=prometheus-mysqld-exporter; fi
  ssh_ app 'systemctl stop shop'
  ssh_ db "systemctl stop mariadb postgresql@18-main prometheus-mysqld-exporter prometheus-postgres-exporter; sync; echo 3 > /proc/sys/vm/drop_caches; systemctl start $unit; sleep 3; systemctl start $exporter"
  ssh_ app "cp /etc/shop-$1.env /etc/shop.env; sed -i \"s/^DB_POOL=.*/DB_POOL=${DB_POOL_MODE:-on}/\" /etc/shop.env; export DB_KIND=$1 DB_DSN=\"\$(grep ^DB_DSN= /etc/shop.env | cut -d= -f2-)\"; shop seed -products ${PRODUCTS:-100000} -orders ${ORDERS:-1000000} 2>&1 | tail -1 | sed 's/:[^:@]*@/:***@/'; systemctl start shop; sleep 2; curl -s -o /dev/null -w 'app %{http_code}\n' $APP/orders/999999"
  sleep 30   # let checkpoints and background flushing from the load settle
}
for kind in postgres mariadb; do
  echo "=== $ROUND $kind  $(date +%T)"
  use $kind
  walstat() { [ $kind = postgres ] && ssh_ db "sudo -u postgres psql -Atc \"select 'wal $1 records='||wal_records||' full_pages='||wal_fpi||' bytes='||wal_bytes from pg_stat_wal; select 'checkpoints $1 timed='||num_timed||' requested='||num_requested from pg_stat_checkpointer\"" || true; }
  walstat before
  ./run-users.sh "$ROUND-$kind" "$WRITES" "$USERS" "$HOLD" 2>&1 | grep -A12 '^ users' || true
  walstat after
done
