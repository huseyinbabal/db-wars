#!/usr/bin/env bash
# Install everything on the machines from up.sh. The app (cgo, C SQLite inside) is built once on pg-srv and copied to sl-srv,
# so both machines run the identical binary.
set -euo pipefail
cd "$(dirname "$0")"; R=../run; source $R/hosts.env
ssh_() { ssh -F $R/ssh_config -o ConnectTimeout=10 "$@"; }
scp_() { scp -F $R/ssh_config -q "$@"; }
for h in pg-srv sl-srv pg-load sl-load mon; do until ssh_ $h true 2>/dev/null; do sleep 3; done; done
for s in pg sl; do
  S=$(echo $s | tr a-z A-Z); SRV=${S}_SRV_IP; LOAD=${S}_LOAD_IP
  scp_ srv.sh $s-srv:/root/ && ssh_ $s-srv "SRV_IP=${!SRV} bash /root/srv.sh" > $R/setup-$s-srv.log 2>&1 &
  scp_ load.sh ../k6/shop.js $s-load:/root/ && ssh_ $s-load "LOAD_IP=${!LOAD} bash /root/load.sh" > $R/setup-$s-load.log 2>&1 &
done
scp_ mon.sh mon:/root/ && ssh_ mon "PG_SRV_IP=$PG_SRV_IP SL_SRV_IP=$SL_SRV_IP PG_LOAD_IP=$PG_LOAD_IP SL_LOAD_IP=$SL_LOAD_IP MON_IP=$MON_IP bash /root/mon.sh" > $R/setup-mon.log 2>&1 &
wait
# build: Go from go.dev, then the app from source
ssh_ pg-srv 'mkdir -p /root/src' && scp_ ../app/main.go ../app/seed.go ../app/go.mod ../app/go.sum pg-srv:/root/src/
ssh_ pg-srv 'set -e; [ -x /usr/local/go/bin/go ] || curl -fsSL https://go.dev/dl/go1.27.1.linux-amd64.tar.gz | tar -xz -C /usr/local
  cd /root/src && CGO_ENABLED=1 /usr/local/go/bin/go build -trimpath -o /usr/local/bin/shop . && ls -l /usr/local/bin/shop' > $R/build.log 2>&1
scp_ pg-srv:/usr/local/bin/shop $R/shop && scp_ $R/shop sl-srv:/usr/local/bin/shop && ssh_ sl-srv 'chmod +x /usr/local/bin/shop'
tail -n 3 $R/setup-*.log $R/build.log
