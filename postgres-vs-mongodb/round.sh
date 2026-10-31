#!/usr/bin/env bash
# One round on both stacks at the same moment: same data, same k6 script, same rate steps.
#   ./round.sh <name> <mix> <items per order> <START> <STEP> <STEPS> <HOLD> [orders]
# pg stack runs Postgres, mg stack runs MongoDB. SWAP=1 runs them the other way round (host check).
set -euo pipefail
cd "$(dirname "$0")"; R=run; source $R/hosts.env
NAME=$1; MIX=$2; ITEMS=$3; START=$4; STEP=$5; STEPS=$6; HOLD=$7; ORDERS=${8:-1000000}
ssh_() { ssh -F $R/ssh_config "$@"; }
OUT=results/$NAME; mkdir -p $OUT
kind_of() { if [ "${SWAP:-0}" = 1 ]; then [ $1 = pg ] && echo mongo || echo postgres; else [ $1 = pg ] && echo postgres || echo mongo; fi; }

use() {  # $1 = stack: stop everything, start one database, load fresh data, start the app
  local s=$1 kind; kind=$(kind_of $s)
  ssh_ $s-app 'systemctl stop docshop'
  if [ $kind = postgres ]; then
    ssh_ $s-db 'systemctl stop mongod mongodb-exporter postgresql prometheus-postgres-exporter; sync; echo 3 > /proc/sys/vm/drop_caches
      echo madvise > /sys/kernel/mm/transparent_hugepage/enabled; systemctl start postgresql; sleep 3; systemctl start prometheus-postgres-exporter'
  else  # MongoDB 8.0+ production notes: transparent huge pages on
    ssh_ $s-db 'systemctl stop mongod mongodb-exporter postgresql prometheus-postgres-exporter; sync; echo 3 > /proc/sys/vm/drop_caches
      echo always > /sys/kernel/mm/transparent_hugepage/enabled; echo defer+madvise > /sys/kernel/mm/transparent_hugepage/defrag
      systemctl start mongod; for i in $(seq 30); do mongosh --quiet --eval 1 >/dev/null 2>&1 && break; sleep 1; done; systemctl start mongodb-exporter'
  fi
  ssh_ $s-app "cp /etc/docshop-$kind.env /etc/docshop.env; echo ITEMS=$ITEMS >> /etc/docshop.env
    while IFS= read -r l; do export \"\$l\"; done < /etc/docshop.env; docshop seed -orders $ORDERS -items $ITEMS 2>&1 | tail -3 | sed 's/:[^:@]*@/:***@/'
    [ $kind = postgres ] && [ -n \"${PG_TUNE:-}\" ] && psql \"\$DB_DSN\" -qc \"${PG_TUNE:-}\" && echo 'tuned: ${PG_TUNE:-}'
    systemctl start docshop; sleep 2; curl -s -o /dev/null -w '$kind app %{http_code}\n' http://\$ADDR/healthz || true"
}
use pg > $OUT/use-pg.log 2>&1 & use mg > $OUT/use-mg.log 2>&1 & wait
cat $OUT/use-*.log
sleep 20   # let checkpoints and background flushing from the load settle

for s in pg mg; do  # console tools on the database machines, one line per second
  ssh_ $s-db "rm -rf /root/run && mkdir -p /root/run && cd /root/run &&
    (nohup vmstat -t 1 > vmstat.log 2>&1 & echo \$! > pids) && (nohup iostat -xt 1 > iostat.log 2>&1 & echo \$! >> pids) &&
    (nohup env COLUMNS=160 top -b -d 2 -c -w 160 > top.log 2>&1 & echo \$! >> pids) &&
    (nohup pidstat -u -r -h -l 1 -C 'postgres|mongod' > pidstat.log 2>&1 & echo \$! >> pids)"
done
for s in pg mg; do  # Postgres internals every 2 s (pgsample.sh)
  if [ $(kind_of $s) = postgres ]; then scp -F $R/ssh_config -q pgsample.sh $s-db:/root/run/; ssh_ $s-db 'cd /root/run && (nohup sh pgsample.sh > gin.log 2>&1 & echo $! >> pids)'; fi
done
if [ "${RECORD:-0}" = 1 ]; then  # optional: record the live side-by-side Grafana dashboard (needs a recorder, not included)
  python3 grafana/gen_dash.py $(( (START + STEP * (STEPS - 1)) * 11 / 10 )) > $OUT/live.json
  scp -F $R/ssh_config -q $OUT/live.json mon:/var/lib/grafana/dashboards/live.json; sleep 12
  pkill -f 'L 3300:127.0.0.1:3000' || true; ssh -F $R/ssh_config -f -N -L 3300:127.0.0.1:3000 mon
  node grafana/record.mjs $(( STEPS * (${HOLD%s} + 5) + 15 )) $PWD/$OUT/live.mp4 "http://127.0.0.1:3300/d/dbwars2-live?kiosk&theme=dark&refresh=1s&from=$(( $(date +%s) * 1000 - 5000 ))&to=now" > $OUT/record.log 2>&1 &
  REC=$!
fi
date +%s > $OUT/start
for s in pg mg; do
  S=$(echo $s | tr a-z A-Z); APP=${S}_APP_IP; kind=$(kind_of $s)
  ssh_ $s-load "K6_PROMETHEUS_RW_SERVER_URL=http://$MON_IP:9090/api/v1/write K6_PROMETHEUS_RW_TREND_AS_NATIVE_HISTOGRAM=true K6_PROMETHEUS_RW_PUSH_INTERVAL=1s \
    k6 run -q -o experimental-prometheus-rw --tag db=$kind --tag run=$NAME --summary-export /root/summary.json \
    -e BASE_URL=http://${!APP}:8000 -e MIX=$MIX -e ORDERS=$ORDERS -e START=$START -e STEP=$STEP -e STEPS=$STEPS -e HOLD=$HOLD /root/doc.js" > $OUT/k6-$kind.log 2>&1 &
done
wait
date +%s > $OUT/end
[ -n "${REC:-}" ] && wait $REC || true
sleep 6
for s in pg mg; do
  kind=$(kind_of $s); mkdir -p $OUT/$kind
  ssh_ $s-db 'kill $(cat /root/run/pids) 2>/dev/null; true'; scp -F $R/ssh_config -q "$s-db:/root/run/*.log" $OUT/$kind/
  scp -F $R/ssh_config -q $s-load:/root/summary.json $OUT/$kind/summary.json
done
scp -F $R/ssh_config -q series2.py mon:/root/
ssh_ mon "python3 /root/series2.py http://$MON_IP:9090 $(cat $OUT/start) $(cat $OUT/end) ${SWAP:-0}" > $OUT/series.json
python3 steps2.py $OUT $START $STEP $HOLD
