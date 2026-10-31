SELECT now()::time(0) t,
  (SELECT n_dead_tup FROM pg_stat_user_tables WHERE relname='orders') dead,
  (SELECT pending_pages FROM pgstatginindex('orders_items')) gin_pending_pages,
  (SELECT count(*) FROM pg_stat_activity WHERE backend_type='autovacuum worker') autovac,
  (SELECT string_agg(left(query,40),' | ') FROM pg_stat_activity WHERE backend_type='autovacuum worker') av_query,
  (SELECT count(*) FROM pg_stat_activity WHERE wait_event IS NOT NULL AND backend_type='client backend' AND state='active') waiting,
  (SELECT string_agg(DISTINCT wait_event,',') FROM pg_stat_activity WHERE backend_type='client backend' AND state='active') waits;
