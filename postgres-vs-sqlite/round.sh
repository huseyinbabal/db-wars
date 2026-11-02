#!/usr/bin/env bash
# One round on both stacks at the same moment: same data, same k6 script, same rate steps.
#   ./round.sh <name> <WRITES share> <START> <STEP> <STEPS> <HOLD>
# pg stack runs Postgres, sl stack runs SQLite. SWAP=1 runs them the other way round (host check).
# LITE_WRITERS=1: SQLite writes go through their own pool of exactly one connection. PG_POOL=n: Postgres pool size (default 100).
set -euo pipefail
cd "$(dirname "$0")"; R=run; source $R/hosts.env
NAME=$1; WRITES=$2; START=$3; STEP=$4; STEPS=$5; HOLD=$6
ssh_() { ssh -F $R/ssh_config "$@"; }
OUT=results/$NAME; mkdir -p $OUT
kind_of() { if [ "${SWAP:-0}" = 1 ]; then [ $1 = pg ] && echo sqlite || echo postgres; else [ $1 = pg ] && echo postgres || echo sqlite; fi; }

use() {  # $1 = stack: stop everything, start one database, load fresh data, start the app
  local s=$1 kind; kind=$(kind_of $s)
  ssh_ $s-srv "systemctl stop shop postgresql prometheus-postgres-exporter; rm -f /var/lib/shop/shop.db*; sync; echo 3 > /proc/sys/vm/drop_caches
    cp /etc/shop-$kind.env /etc/shop.env; echo SQLITE_WRITERS=${LITE_WRITERS:-0} >> /etc/shop.env; [ $kind = postgres ] && [ -n \"${PG_POOL:-}\" ] && echo DB_MAX_OPEN=${PG_POOL:-} >> /etc/shop.env; true
    if [ $kind = postgres ]; then systemctl start postgresql; sleep 3; sudo -u postgres psql -qc 'DROP DATABASE IF EXISTS shop' -c 'CREATE DATABASE shop OWNER shop'; systemctl start prometheus-postgres-exporter; fi
    while IFS= read -r l; do export \"\$l\"; done < /etc/shop.env; shop seed -products 100000 -orders 1000000 2>&1 | tail -2
    [ $kind = sqlite ] && ls -la /var/lib/shop | tail -n +4 | awk '{print \$5, \$9}'
    systemctl start shop; sleep 2; curl -s -o /dev/null -w '$kind app %{http_code}\n' http://\$ADDR/healthz || true"
}
use pg > $OUT/use-pg.log 2>&1 & use sl > $OUT/use-sl.log 2>&1 & wait
cat $OUT/use-*.log
sleep 20   # let checkpoints and background flushing from the load settle

for s in pg sl; do  # console tools on the server machines, one line per second
  ssh_ $s-srv "rm -rf /root/run && mkdir -p /root/run && cd /root/run &&
    (nohup vmstat -t 1 > vmstat.log 2>&1 & echo \$! > pids) && (nohup iostat -xt 1 > iostat.log 2>&1 & echo \$! >> pids) &&
    (nohup env COLUMNS=160 top -b -d 2 -c -w 160 > top.log 2>&1 & echo \$! >> pids) &&
    (nohup pidstat -u -r -h -l 1 -C 'postgres|shop' > pidstat.log 2>&1 & echo \$! >> pids) &&
    (nohup sh -c 'while true; do date +%s; curl -s http://\$(grep ^ADDR /etc/shop.env | cut -d= -f2)/metrics; sleep 2; done' > pool.log 2>&1 & echo \$! >> pids)"
done
date +%s > $OUT/start
for s in pg sl; do
  S=$(echo $s | tr a-z A-Z); SRV=${S}_SRV_IP; kind=$(kind_of $s)
  ssh_ $s-load "K6_PROMETHEUS_RW_SERVER_URL=http://$MON_IP:9090/api/v1/write K6_PROMETHEUS_RW_TREND_AS_NATIVE_HISTOGRAM=true K6_PROMETHEUS_RW_PUSH_INTERVAL=1s \
    k6 run -q -o experimental-prometheus-rw --tag db=$kind --tag run=$NAME --summary-export /root/summary.json \
    -e BASE_URL=http://${!SRV}:8000 -e WRITES=$WRITES -e START=$START -e STEP=$STEP -e STEPS=$STEPS -e HOLD=$HOLD /root/shop.js" > $OUT/k6-$kind.log 2>&1 &
done
wait
date +%s > $OUT/end
sleep 6
for s in pg sl; do
  kind=$(kind_of $s); mkdir -p $OUT/$kind
  ssh_ $s-srv 'kill $(cat /root/run/pids) 2>/dev/null; journalctl -u shop --since "-15 min" --no-pager | tail -40 > /root/run/shop.log; true'
  scp -F $R/ssh_config -q "$s-srv:/root/run/*.log" $OUT/$kind/
  scp -F $R/ssh_config -q $s-load:/root/summary.json $OUT/$kind/summary.json
done
scp -F $R/ssh_config -q series.py mon:/root/
ssh_ mon "python3 /root/series.py http://$MON_IP:9090 $(cat $OUT/start) $(cat $OUT/end) ${SWAP:-0}" > $OUT/series.json
python3 steps.py $OUT $START $STEP $HOLD
