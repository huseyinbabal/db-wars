#!/bin/sh
# Postgres internals every 2 s during a round: GIN pending list of the items index, dead and live rows, running autovacuum workers.
Q="SELECT p.pending_pages, p.pending_tuples, t.n_dead_tup, t.n_live_tup,
  (SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'autovacuum worker')
  FROM pgstatginindex('orders_items') p, pg_stat_user_tables t WHERE t.relname = 'orders'"
echo "time pending_pages pending_tuples dead live autovacuum"
while :; do echo "$(date +%T) $(sudo -u postgres psql -d shop -AtF' ' -c "$Q" 2>&1)"; sleep 2; done
