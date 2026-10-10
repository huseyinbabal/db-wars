#!/usr/bin/env bash
# One load test on three machines (ssh hosts: load = k6 + Prometheus, app = Go service, db = database only).
# Console tools run on db and app, k6 on load, everything is copied to results/<name>/
#   SSH_CONF=<ssh config> APP=http://<app private ip>:8000 ./run-users.sh <name> <writes 0..1> [users like 100,200,400] [HOLD seconds]
set -euo pipefail
cd "$(dirname "$0")"
NAME=$1; WRITES=$2; USERS=${3:-100,200,400,800,1600}; HOLD=${4:-170}
ssh_() { ssh -F "$SSH_CONF" "$@"; }
OUT=results/$NAME; mkdir -p "$OUT/db" "$OUT/app"

# the console tools, one line per second, each with its own clock
for h in db app; do
  ssh_ $h "rm -rf /root/run && mkdir -p /root/run && cd /root/run &&
    (nohup vmstat -t 1 > vmstat.log 2>&1 & echo \$! > pids) &&
    (nohup iostat -xt 1 > iostat.log 2>&1 & echo \$! >> pids) &&
    (nohup env COLUMNS=160 top -b -d 2 -c -w 160 > top.log 2>&1 & echo \$! >> pids) &&
    (nohup pidstat -u -r -h -l 1 -C 'postgres|mariadbd|shop' > pidstat.log 2>&1 & echo \$! >> pids) &&
    (nohup sh -c 'while :; do echo \"\$(date +%T) \$(cat /proc/loadavg)\"; sleep 1; done' > loadavg.log 2>&1 & echo \$! >> pids)"
done
scp -F "$SSH_CONF" -q k6/users.js series.py load:/root/
date +%s > "$OUT/start"
ssh_ load "K6_PROMETHEUS_RW_SERVER_URL=http://127.0.0.1:9090/api/v1/write K6_PROMETHEUS_RW_TREND_AS_NATIVE_HISTOGRAM=true \
  k6 run -o experimental-prometheus-rw --tag run=$NAME --summary-export /root/summary.json \
  -e BASE_URL=$APP -e PRODUCTS=${PRODUCTS:-100000} -e ORDERS=${ORDERS:-1000000} -e WRITES=$WRITES -e USERS=$USERS -e HOLD=$HOLD /root/users.js" 2>&1 | tee "$OUT/k6.log" | grep -vE '^\s*$|running \(|default|shop +\[' || true
date +%s > "$OUT/end"
sleep 6
for h in db app; do ssh_ $h 'kill $(cat /root/run/pids) 2>/dev/null; true'; scp -F "$SSH_CONF" -q "$h:/root/run/*.log" "$OUT/$h/"; done
scp -F "$SSH_CONF" -q load:/root/summary.json "$OUT/"
ssh_ load "python3 /root/series.py $(cat "$OUT/start") $(cat "$OUT/end")" > "$OUT/series.json"
python3 stages.py "$OUT" "$USERS" "$HOLD"
