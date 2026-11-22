#!/usr/bin/env bash
# usage: bench.sh <pg image tag> <outdir> [size divisor, 1 = full]
# Same container settings for every version; each test repeated $RUNS times on a fresh table.
set -euo pipefail
V=$1; OUT=$2; D=${3:-1}; RUNS=${RUNS:-5}
mkdir -p "$OUT"; R="$OUT/pg$V.jsonl"; : > "$R"
C=pgb-$V
docker rm -f $C >/dev/null 2>&1 || true
docker run -d --name $C --shm-size=2g -e POSTGRES_PASSWORD=bench postgres:$V \
  -c shared_buffers=${SB:-2GB} -c maintenance_work_mem=1GB -c max_wal_size=16GB \
  -c checkpoint_timeout=30min -c jit=off -c log_autovacuum_min_duration=0 >/dev/null
until docker exec $C pg_isready -U postgres -q 2>/dev/null; do sleep 1; done; sleep 2
q()  { docker exec -i $C psql -U postgres -v ON_ERROR_STOP=1 -qAt "$@"; }
ms() { # run SQL, print elapsed ms from \timing
  docker exec -i $C psql -U postgres -v ON_ERROR_STOP=1 -qAt -c '\timing on' -c "$1" | sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' | tail -1; }
rec(){ echo "{\"version\":\"$V\",\"test\":\"$1\",\"run\":$2,\"value\":$3,\"unit\":\"$4\"}" >> "$R"; echo "$V $1 run$2 = $3 $4"; }
docker exec $C psql -U postgres -qAt -c "alter system set autovacuum = off" -c "select pg_reload_conf()" >/dev/null
q -c "select version()" > "$OUT/pg$V.version"
q -c "select name, setting from pg_settings where source <> 'default' order by 1" > "$OUT/pg$V.settings"

PARENT=$((1000000/D)); CHILD=$((5000000/D))
# ---------- T1: foreign key bulk insert ----------
q <<SQL
create table parent(id int primary key, name text);
insert into parent select i, 'p'||i from generate_series(1,$PARENT) i;
vacuum analyze parent;
copy (select (i % $PARENT)+1, md5(i::text) from generate_series(1,$CHILD) i) to '/tmp/child.csv' (format csv);
SQL
for fk in fk nofk; do
  ref=""; [ $fk = fk ] && ref="references parent(id)"
  for r in $(seq 1 $RUNS); do
    q -c "drop table if exists child; create table child(id bigint generated always as identity, parent_id int $ref, payload text); checkpoint;"
    rec "insert_select_$fk" $r "$(ms "insert into child(parent_id,payload) select (i % $PARENT)+1, md5(i::text) from generate_series(1,$CHILD) i")" ms
    q -c "truncate child; checkpoint;"
    rec "copy_$fk" $r "$(ms "copy child(parent_id,payload) from '/tmp/child.csv' (format csv)")" ms
  done
done
# single-row inserts from 16 clients (OLTP style), 60 s each
docker exec $C sh -c "printf '\\\\set p random(1,$PARENT)\ninsert into child(parent_id,payload) values (:p, md5(:p::text));\n' > /tmp/ins.sql"
for fk in fk nofk; do
  ref=""; [ $fk = fk ] && ref="references parent(id)"
  for r in $(seq 1 $RUNS); do
    q -c "drop table if exists child; create table child(id bigint generated always as identity, parent_id int $ref, payload text); checkpoint;"
    tps=$(docker exec $C pgbench -U postgres -n -c 16 -j 4 -T ${T:-60} -f /tmp/ins.sql postgres | sed -n 's/^tps = \([0-9.]*\).*/\1/p')
    rec "pgbench_insert_$fk" $r "$tps" tps
  done
done
q -c "drop table child; drop table parent;"

# ---------- T2: NOT IN (b fits work_mem as a hash / b does not fit) ----------
for case in small:$((100000/D)) large:$((1000000/D)); do
  name=${case%%:*}; nb=${case##*:}
  q <<SQL
drop table if exists a, b;
create table a(x int not null); create table b(y int not null);
insert into a select i from generate_series(1,$((5000000/D))) i;
insert into b select i*3 from generate_series(1,$nb) i;
vacuum analyze a, b;
SQL
  q -c "explain select count(*) from a where x not in (select y from b)" > "$OUT/pg$V.notin_$name.plan"
  for r in $(seq 1 $RUNS); do
    v=$(docker exec -i $C psql -U postgres -qAt -c "set statement_timeout='120s'" -c '\timing on' -c "select count(*) from a where x not in (select y from b)" 2>&1 | sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' | tail -1 || true)
    rec notin_$name $r "${v:-null}" ms
    [ -z "$v" ] && { echo "notin_$name timed out (120 s), skipping remaining runs"; break; }
  done
done
q -c "drop table a, b;"

# ---------- T3: TOAST default compression (stock default) ----------
q <<SQL
create table docs(id int, body jsonb);
insert into docs select i, (select jsonb_agg(jsonb_build_object('k', j, 'v', md5((i*j)::text), 'tag', 'order-item')) from generate_series(1,200) j) from generate_series(1,$((50000/D))) i;
SQL
for r in 1; do rec toast_size $r "$(q -c "select pg_total_relation_size('docs')")" bytes; done
q -c "select pg_column_compression(body), count(*) from docs group by 1" > "$OUT/pg$V.toast"
q -c "drop table docs;"

# ---------- T4: bloat removal under load ----------
bloat() {
q <<SQL
drop table if exists acct;
create table acct(id int primary key, balance int, note text);
insert into acct select i, 0, repeat('x',200) from generate_series(1,$((5000000/D))) i;
delete from acct where id % 5 <> 0;
vacuum analyze acct;
SQL
}
docker exec $C sh -c "printf '\\\\set id random(1,$((1000000/D)))\nupdate acct set balance = balance + 1 where id = :id * 5;\nselect balance from acct where id = :id * 5;\n' > /tmp/oltp.sql"
cmds=("vacuum full acct"); [ "${V%%.*}" -ge 19 ] && cmds+=("repack acct" "repack (concurrently) acct")
for cmd in "${cmds[@]}"; do
  tag=$(echo "$cmd" | tr -c 'a-z\n' '_' | sed 's/_*$//;s/__*/_/g')
  for r in $(seq 1 ${RUNS_BLOAT:-3}); do
    bloat
    before=$(q -c "select pg_total_relation_size('acct')")
    docker exec $C pgbench -U postgres -n -c 8 -j 4 -T 90 -P 1 -f /tmp/oltp.sql postgres > "$OUT/pg$V.$tag.$r.pgbench" 2>&1 &
    PB=$!; sleep 20
    t=$(ms "$cmd"); wait $PB
    after=$(q -c "select pg_total_relation_size('acct')")
    rec "${tag}_time" $r "$t" ms; rec "${tag}_size_before" $r "$before" bytes; rec "${tag}_size_after" $r "$after" bytes
    # lowest per-second tps while the command ran (from -P 1 progress lines)
    mn=$(grep -o 'progress: [0-9.]* s, [0-9.]* tps' "$OUT/pg$V.$tag.$r.pgbench" | awk -v a=21 -v b=$((21+${t%.*}/1000)) '{s=$2+0; if(s>=a && s<=b){ if(min==""||$4<min)min=$4 }} END{print (min==""?"null":min)}')
    rec "${tag}_min_tps" $r "$mn" tps
  done
done
q -c "drop table acct;"

# ---------- T5: autovacuum with parallel index workers ----------
if [ "${V%%.*}" -ge 19 ]; then pw_list="0 4"; else pw_list="0"; fi
for pw in $pw_list; do
  for r in $(seq 1 ${RUNS_BLOAT:-3}); do
    q <<SQL
drop table if exists wide;
create table wide(id int primary key, a int, b int, c int, d int, e int, f int, g int, h text);
insert into wide select i, i, i, i, i, i, i, i, md5(i::text) from generate_series(1,$((5000000/D))) i;
create index on wide(a); create index on wide(b); create index on wide(c); create index on wide(d);
create index on wide(e); create index on wide(f); create index on wide(g); create index on wide(h);
delete from wide where id % 2 = 0;
SQL
    [ "${V%%.*}" -ge 19 ] && q -c "alter system set autovacuum_max_parallel_workers = $pw" -c "alter table wide set (autovacuum_parallel_workers = $pw)"
    q -c "alter system set autovacuum = on" -c "select pg_reload_conf()" >/dev/null
    mark=$(docker logs $C 2>&1 | wc -l)
    for i in $(seq 1 600); do docker logs $C 2>&1 | tail -n +$((mark+1)) | grep -q 'automatic vacuum of table "postgres.public.wide"' && break; sleep 1; done
    line=$(docker logs $C 2>&1 | tail -n +$((mark+1)) | grep -A30 'automatic vacuum of table "postgres.public.wide"' | grep -m1 'system usage' || true)
    el=$(echo "$line" | sed -n 's/.*elapsed: \([0-9.]*\) s.*/\1/p')
    docker logs $C 2>&1 | tail -n +$((mark+1)) | grep -A30 'automatic vacuum of table "postgres.public.wide"' > "$OUT/pg$V.autovac.pw$pw.$r.log" || true
    rec "autovacuum_pw$pw" $r "${el:-null}" s
    q -c "alter system set autovacuum = off" -c "select pg_reload_conf()" >/dev/null
  done
done
docker rm -f $C >/dev/null
echo done
