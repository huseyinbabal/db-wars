#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; R=../run; source $R/hosts.env
ssh_() { ssh -F $R/ssh_config -o ConnectTimeout=10 "$@"; }
scp_() { scp -F $R/ssh_config -q "$@"; }
for h in kv-db kv-app kv-load kv-mon; do n=0; until ssh_ $h true 2>/dev/null; do sleep 3; n=$((n+1)); [ $n -gt 60 ] && { echo "no ssh to $h"; exit 1; }; done; done
scp_ db.sh kv-db:/root/ && ssh_ kv-db "DB_IP=$KV_DB_IP bash /root/db.sh" > $R/setup-db.log 2>&1 &
scp_ $R/kvshop kv-app:/usr/local/bin/kvshop && scp_ app.sh kv-app:/root/ && ssh_ kv-app "DB_IP=$KV_DB_IP APP_IP=$KV_APP_IP bash /root/app.sh" > $R/setup-app.log 2>&1 &
scp_ load.sh ../k6/shop.js kv-load:/root/ && ssh_ kv-load "LOAD_IP=$KV_LOAD_IP bash /root/load.sh" > $R/setup-load.log 2>&1 &
scp_ mon.sh kv-mon:/root/ && ssh_ kv-mon "DB_IP=$KV_DB_IP APP_IP=$KV_APP_IP LOAD_IP=$KV_LOAD_IP MON_IP=$KV_MON_IP bash /root/mon.sh" > $R/setup-mon.log 2>&1 &
wait
tail -n 3 $R/setup-*.log
