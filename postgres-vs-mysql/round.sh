#!/usr/bin/env bash
# One round on both stacks at the same moment: same data, same k6 script, same rate steps.
#   ./round.sh <name> <mix> <START> <STEP> <STEPS> <HOLD> [orders]
# pg stack runs Postgres, my stack runs MySQL. SWAP=1 runs them the other way round (host check).
set -euo pipefail
cd "$(dirname "$0")"; R=run; source $R/hosts.env
NAME=$1; MIX=$2; START=$3; STEP=$4; STEPS=$5; HOLD=$6; ORDERS=${7:-5000000}
ssh_() { ssh -F $R/ssh_config "$@"; }
OUT=results/$NAME; mkdir -p $OUT
kind_of() { if [ "${SWAP:-0}" = 1 ]; then [ $1 = pg ] && echo mysql || echo postgres; else [ $1 = pg ] && echo postgres || echo mysql; fi; }

use() {  # $1 = stack: stop everything, start one database, load fresh data, start the app
  local s=$1 kind; kind=$(kind_of $s)
  ssh_ $s-app 'systemctl stop shop'
  ssh_ $s-db 'systemctl stop mysql prometheus-mysqld-exporter postgresql prometheus-postgres-exporter; sync; echo 3 > /proc/sys/vm/drop_caches'
  ssh_ $s-db "rm -f /etc/mysql/mysql.conf.d/98-tune.cnf; [ '${MY_PFS_OFF:-0}' = 1 ] && printf '[mysqld]\nperformance_schema = OFF\n' > /etc/mysql/mysql.conf.d/98-tune.cnf; true"
  if [ $kind = postgres ]; then ssh_ $s-db 'systemctl start postgresql; sleep 3; systemctl start prometheus-postgres-exporter'
  else ssh_ $s-db 'systemctl start mysql; sleep 3; systemctl start prometheus-mysqld-exporter'; fi
  ssh_ $s-app "cp /etc/shop-$kind.env /etc/shop.env
    while IFS= read -r l; do export \"\$l\"; done < /etc/shop.env; shop seed -products 100000 -orders $ORDERS 2>&1 | tail -3 | sed 's/:[^:@]*@/:***@/'
    systemctl start shop; sleep 2; curl -s -o /dev/null -w '$kind app %{http_code}\n' http://\$ADDR/healthz || true"
}
use pg > $OUT/use-pg.log 2>&1 & use my > $OUT/use-my.log 2>&1 & wait
cat $OUT/use-*.log
sleep 20   # let checkpoints and background flushing from the load settle

for s in pg my; do  # console tools on the database machines, one line per second
  ssh_ $s-db "rm -rf /root/run && mkdir -p /root/run && cd /root/run &&
    (nohup vmstat -t 1 > vmstat.log 2>&1 & echo \$! > pids) && (nohup iostat -xt 1 > iostat.log 2>&1 & echo \$! >> pids) &&
    (nohup env COLUMNS=160 top -b -d 2 -c -w 160 > top.log 2>&1 & echo \$! >> pids) &&
    (nohup pidstat -u -r -h -l 1 -C 'postgres|mysqld' > pidstat.log 2>&1 & echo \$! >> pids)"
done
for s in pg my; do  # sizes, dead rows and undo backlog every 30 s
  scp -F $R/ssh_config -q sample.sh $s-db:/root/run/; ssh_ $s-db "cd /root/run && (nohup sh sample.sh $(kind_of $s) > sizes.log 2>&1 & echo \$! >> pids)"
done
if [ -n "${LONG_TX:-}" ]; then  # a transaction left open during the round: one snapshot that neither database may clean up behind
  ssh_ pg-db "cd /root/run && (nohup sudo -u postgres psql -d shop -c 'BEGIN ISOLATION LEVEL REPEATABLE READ' -c 'SELECT count(*) FROM products WHERE id=1' -c 'SELECT pg_sleep($LONG_TX)' > tx.log 2>&1 & echo \$! >> pids)"
  ssh_ my-db "cd /root/run && (nohup mysql shop -e 'SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ; START TRANSACTION WITH CONSISTENT SNAPSHOT; SELECT count(*) FROM products WHERE id=1; SELECT SLEEP($LONG_TX)' > tx.log 2>&1 & echo \$! >> pids)"
fi
if [ "${RECORD:-0}" = 1 ]; then  # optional: record the live side-by-side Grafana dashboard (needs a recorder, not included)
  python3 grafana/gen_dash.py $(( (START + STEP * (STEPS - 1)) * 11 / 10 )) > $OUT/live.json
  scp -F $R/ssh_config -q $OUT/live.json mon:/var/lib/grafana/dashboards/live.json; sleep 12
  pkill -f 'L 3300:127.0.0.1:3000' || true; ssh -F $R/ssh_config -f -N -L 3300:127.0.0.1:3000 mon
  node grafana/record.mjs $(( STEPS * (${HOLD%s} + 5) + 15 )) $PWD/$OUT/live.mp4 "http://127.0.0.1:3300/d/dbwars2-live?kiosk&theme=dark&refresh=1s&from=$(( $(date +%s) * 1000 - 5000 ))&to=now" > $OUT/record.log 2>&1 &
  REC=$!
fi
date +%s > $OUT/start
for s in pg my; do
  S=$(echo $s | tr a-z A-Z); APP=${S}_APP_IP; kind=$(kind_of $s)
  ssh_ $s-load "K6_PROMETHEUS_RW_SERVER_URL=http://$MON_IP:9090/api/v1/write K6_PROMETHEUS_RW_TREND_AS_NATIVE_HISTOGRAM=true K6_PROMETHEUS_RW_PUSH_INTERVAL=1s \
    k6 run -q -o experimental-prometheus-rw --tag db=$kind --tag run=$NAME --summary-export /root/summary.json \
    -e BASE_URL=http://${!APP}:8000 -e MIX=$MIX -e ORDERS=$ORDERS -e START=$START -e STEP=$STEP -e STEPS=$STEPS -e HOLD=$HOLD /root/shop.js" > $OUT/k6-$kind.log 2>&1 &
done
wait
date +%s > $OUT/end
[ -n "${REC:-}" ] && wait $REC || true
sleep 6
for s in pg my; do
  kind=$(kind_of $s); mkdir -p $OUT/$kind
  ssh_ $s-db 'kill $(cat /root/run/pids) 2>/dev/null; true'; scp -F $R/ssh_config -q "$s-db:/root/run/*.log" $OUT/$kind/
  scp -F $R/ssh_config -q $s-load:/root/summary.json $OUT/$kind/summary.json
done
scp -F $R/ssh_config -q series2.py mon:/root/
ssh_ mon "python3 /root/series2.py http://$MON_IP:9090 $(cat $OUT/start) $(cat $OUT/end) ${SWAP:-0}" > $OUT/series.json
python3 steps2.py $OUT $START $STEP $HOLD
