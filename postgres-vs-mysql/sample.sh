#!/bin/sh
# Every 30 s on the database machine: table and index size, dead rows or undo backlog. $1 = postgres or mysql.
while true; do
  printf '%s ' "$(date +%s)"
  if [ "$1" = postgres ]; then
    sudo -u postgres psql -d shop -Atc "SELECT pg_table_size('orders'), pg_indexes_size('orders'), n_live_tup, n_dead_tup, n_tup_upd, n_tup_hot_upd, autovacuum_count FROM pg_stat_user_tables WHERE relname='orders'" | tr '|' ' '
    du -sb /var/lib/postgresql/18/main/pg_wal | cut -f1
  else
    mysql -N -e "SELECT data_length, index_length, table_rows FROM information_schema.tables WHERE table_schema='shop' AND table_name='orders'; SELECT count FROM information_schema.innodb_metrics WHERE name='trx_rseg_history_len'" | tr '\t\n' '  '
    stat -c %s /var/lib/mysql/shop/orders.ibd; du -sbc /var/lib/mysql/undo_* | tail -1 | cut -f1
  fi | tr '\n' ' '
  echo; sleep 30
done
