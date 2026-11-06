#!/usr/bin/env bash
# Install everything on the machines from up.sh. Passwords are made here, live only in this shell and on the machines.
set -euo pipefail
cd "$(dirname "$0")"; R=../run; source $R/hosts.env
ssh_() { ssh -F $R/ssh_config -o ConnectTimeout=10 "$@"; }
scp_() { scp -F $R/ssh_config -q "$@"; }
PG_PW=$(openssl rand -hex 16); MY_PW=$(openssl rand -hex 16)
(cd ../app && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o ../run/shop .)
for h in pg-db my-db pg-app my-app pg-load my-load mon; do until ssh_ $h true 2>/dev/null; do sleep 3; done; done
for s in pg my; do
  S=$(echo $s | tr a-z A-Z); DB=${S}_DB_IP; APP=${S}_APP_IP; LOAD=${S}_LOAD_IP
  scp_ db.sh $s-db:/root/ && ssh_ $s-db "DB_IP=${!DB} APP_IP=${!APP} PG_PW=$PG_PW MY_PW=$MY_PW bash /root/db.sh" > $R/setup-$s-db.log 2>&1 &
  scp_ $R/shop $s-app:/usr/local/bin/shop && scp_ app.sh $s-app:/root/ && ssh_ $s-app "DB_IP=${!DB} APP_IP=${!APP} PG_PW=$PG_PW MY_PW=$MY_PW bash /root/app.sh" > $R/setup-$s-app.log 2>&1 &
  scp_ load.sh ../k6/shop.js $s-load:/root/ && ssh_ $s-load "LOAD_IP=${!LOAD} bash /root/load.sh" > $R/setup-$s-load.log 2>&1 &
done
scp_ mon.sh mon:/root/ && ssh_ mon "PG_DB_IP=$PG_DB_IP MY_DB_IP=$MY_DB_IP PG_APP_IP=$PG_APP_IP MY_APP_IP=$MY_APP_IP PG_LOAD_IP=$PG_LOAD_IP MY_LOAD_IP=$MY_LOAD_IP MON_IP=$MON_IP bash /root/mon.sh" > $R/setup-mon.log 2>&1 &
wait
tail -n 4 $R/setup-*.log
