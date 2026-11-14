#!/usr/bin/env bash
# One run: fresh server, 1M products, 20 s rest, k6 rate steps.   ./run1.sh <redis|valkey> <io-threads> <name> [START STEP STEPS HOLD]
set -euo pipefail
cd "$(dirname "$0")"; R=run; source $R/hosts.env
KIND=$1; IOT=$2; NAME=$3; START=${4:-10000}; STEP=${5:-10000}; STEPS=${6:-10}; HOLD=${7:-30s}
ssh_() { ssh -F $R/ssh_config -o ConnectTimeout=10 "$@"; }
OUT=results/$NAME/$KIND; mkdir -p $OUT
if [ $KIND = redis ]; then IMG=redis:8.10.3-trixie; BIN=redis-server; CLI=redis-cli; else IMG=valkey/valkey:9.1.3-trixie; BIN=valkey-server; CLI=valkey-cli; fi
ssh_ kv-app 'systemctl stop kvshop' || true
ssh_ kv-db "docker rm -f kv >/dev/null 2>&1; sync; echo 3 > /proc/sys/vm/drop_caches
  docker run -d --name kv --network host $IMG $BIN --bind $KV_DB_IP --port 6379 --protected-mode no --io-threads $IOT >/dev/null
  until docker exec kv $CLI -h $KV_DB_IP PING 2>/dev/null | grep -q PONG; do sleep 0.2; done
  docker exec kv $CLI -h $KV_DB_IP INFO server | grep -E '^(redis_version|valkey_version|server_name)'
  docker exec kv $CLI -h $KV_DB_IP CONFIG GET io-threads | paste -sd' ' -
  systemctl restart kv-exporter" | tee $OUT/server.txt
ssh_ kv-app "KV_ADDR=$KV_DB_IP:6379 /usr/local/bin/kvshop seed -products 1000000 2>&1 | tail -1; systemctl start kvshop; sleep 1; curl -s -o /dev/null -w 'app %{http_code}\n' http://$KV_APP_IP:8000/healthz" | tee $OUT/seed.txt
ssh_ kv-db "docker exec kv $CLI -h $KV_DB_IP INFO memory; docker exec kv $CLI -h $KV_DB_IP DBSIZE; docker exec kv $CLI -h $KV_DB_IP MEMORY USAGE product:1" > $OUT/memory-seeded.txt
sleep 20
ssh_ kv-db "rm -rf /root/run && mkdir -p /root/run && cd /root/run && P=\$(pgrep -x '$BIN' | head -1) &&
  (nohup pidstat -t -u -h -p \$P 1 > pidstat.log 2>&1 & echo \$! > pids) && (nohup vmstat -t 1 > vmstat.log 2>&1 & echo \$! >> pids) &&
  (nohup env COLUMNS=160 top -b -H -d 2 -w 160 -p \$P > top.log 2>&1 & echo \$! >> pids)"
date +%s > $OUT/start
ssh_ kv-load "ulimit -n 200000; K6_PROMETHEUS_RW_SERVER_URL=http://$KV_MON_IP:9090/api/v1/write K6_PROMETHEUS_RW_TREND_AS_NATIVE_HISTOGRAM=true K6_PROMETHEUS_RW_PUSH_INTERVAL=1s \
  k6 run -q -o experimental-prometheus-rw --tag kv=$KIND --tag run=$NAME --summary-export /root/summary.json \
  -e BASE_URL=http://$KV_APP_IP:8000 -e START=$START -e STEP=$STEP -e STEPS=$STEPS -e HOLD=$HOLD /root/shop.js" > $OUT/k6.log 2>&1 || true
date +%s > $OUT/end
ssh_ kv-app "curl -s http://$KV_APP_IP:8000/debug/pool" > $OUT/pool.json
ssh_ kv-db 'kill $(cat /root/run/pids) 2>/dev/null; true'
scp -F $R/ssh_config -q "kv-db:/root/run/*.log" $OUT/; scp -F $R/ssh_config -q kv-load:/root/summary.json $OUT/summary.json
ssh_ kv-db "docker exec kv $CLI -h $KV_DB_IP INFO all" > $OUT/info-after.txt
jq -r --arg k $KIND '"\($k) reqs=\(.metrics.http_reqs.count) rate=\(.metrics.http_reqs.rate|floor) p95=\(.metrics.http_req_duration["p(95)"]|floor) fail=\(.metrics.http_req_failed.value)"' $OUT/summary.json
