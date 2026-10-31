#!/usr/bin/env bash
# Why Postgres falls over in the shop mix: Postgres alone on the pg stack, fresh data, a fixed 300 req/s shop mix for 100 s.
# On the database machine during the load: wait events every 0.5 s, a 20 s perf profile, EXPLAIN of the product search.
#   ./diag.sh <name> [PG_TUNE sql]
set -euo pipefail
cd "$(dirname "$0")"; R=run; source $R/hosts.env
NAME=$1; TUNE=${2:-}; OUT=results/diag-$NAME; mkdir -p $OUT
ssh_() { ssh -F $R/ssh_config "$@"; }
ssh_ pg-app 'systemctl stop docshop'
ssh_ pg-db 'systemctl stop mongod mongodb-exporter postgresql; sync; echo 3 > /proc/sys/vm/drop_caches; echo madvise > /sys/kernel/mm/transparent_hugepage/enabled; systemctl start postgresql'
ssh_ pg-app "cp /etc/docshop-postgres.env /etc/docshop.env; echo ITEMS=3 >> /etc/docshop.env; while IFS= read -r l; do export \"\$l\"; done < /etc/docshop.env
  docshop seed -orders 1000000 -items 3 2>&1 | tail -1; [ -n \"$TUNE\" ] && psql \"\$DB_DSN\" -qc \"$TUNE\"; systemctl start docshop; sleep 2"
sleep 15
cat > $OUT/waits.sql <<'SQL'
SELECT coalesce(wait_event_type, 'CPU') || ':' || coalesce(wait_event, 'running') AS w, count(*) FROM pg_stat_activity
 WHERE backend_type = 'client backend' AND state = 'active' AND pid <> pg_backend_pid() GROUP BY 1 ORDER BY 2 DESC;
SQL
scp -F $R/ssh_config -q $OUT/waits.sql pg-db:/tmp/waits.sql
ssh_ pg-load "k6 run -q -e BASE_URL=http://$PG_APP_IP:8000 -e MIX=shop -e ORDERS=1000000 -e START=300 -e STEP=0 -e STEPS=1 -e HOLD=100s --summary-export /root/diag.json /root/doc.js >/dev/null 2>&1" &
K=$!
sleep 25
ssh_ pg-db 'for i in $(seq 80); do sudo -u postgres psql -d shop -Atq -f /tmp/waits.sql; echo --; sleep .5; done' > $OUT/waits.log 2>&1 &
ssh_ pg-db 'perf record -F 199 -a -g -o /tmp/perf.data -- sleep 20 >/dev/null 2>&1; perf report -i /tmp/perf.data --no-children --sort symbol --stdio 2>/dev/null | grep -E "^ +[0-9]" | head -40' > $OUT/perf-top.txt 2>&1 &
sleep 30
ssh_ pg-db "sudo -u postgres psql -d shop -c \"SELECT * FROM pgstatginindex('orders_items')\" -c \"EXPLAIN (ANALYZE, BUFFERS) SELECT doc FROM orders WHERE doc->'items' @> '[{\\\"product_id\\\":4242}]' LIMIT 10\"" > $OUT/explain.txt 2>&1
wait
scp -F $R/ssh_config -q pg-load:/root/diag.json $OUT/summary.json
python3 - $OUT <<'PY'
import collections, json, sys
o = sys.argv[1]; c = collections.Counter(); n = 0
for block in open(o + '/waits.log').read().split('--'):
    rows = [l.split('|') for l in block.strip().splitlines() if '|' in l]
    if rows: n += 1
    for w, k in rows: c[w] += int(k)
print('average active backends by wait event (', n, 'samples):'); [print(f'  {w:40} {v / n:6.1f}') for w, v in c.most_common(12)]
m = json.load(open(o + '/summary.json'))['metrics']; d = m['http_req_duration']
print(f"k6: {m['http_reqs']['rate']:.0f} req/s  p50 {d['med']:.1f}  p95 {d['p(95)']:.1f}  p99 {d['p(99)']:.1f} ms")
PY
echo; head -25 $OUT/perf-top.txt; echo; cat $OUT/explain.txt
