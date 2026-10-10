#!/usr/bin/env python3
"""Pull the time series of one run from Prometheus as JSON: series.py <start epoch> <end epoch>"""
import json, sys, urllib.parse, urllib.request
T0, T1 = int(sys.argv[1]), int(sys.argv[2])
cpu = lambda m, mode: f'avg(rate(node_cpu_seconds_total{{machine="{m}",mode="{mode}"}}[15s]))*100'
Q = {
    'rps': 'sum(rate(k6_http_reqs_total[15s]))',
    'p50_ms': 'histogram_quantile(0.5,sum(rate(k6_http_req_duration_seconds[15s])))*1000',
    'p95_ms': 'histogram_quantile(0.95,sum(rate(k6_http_req_duration_seconds[15s])))*1000',
    'p99_ms': 'histogram_quantile(0.99,sum(rate(k6_http_req_duration_seconds[15s])))*1000',
    'fail_rate': 'sum(rate(k6_http_req_failed_rate[15s]))',
    'db_load1': 'node_load1{machine="db"}', 'app_load1': 'node_load1{machine="app"}', 'load_load1': 'node_load1{machine="load"}',
    'db_mem_used_mb': '(node_memory_MemTotal_bytes{machine="db"}-node_memory_MemAvailable_bytes{machine="db"})/1048576',
    'db_mem_cache_mb': 'node_memory_Cached_bytes{machine="db"}/1048576',
    'db_swap_used_mb': '(node_memory_SwapTotal_bytes{machine="db"}-node_memory_SwapFree_bytes{machine="db"})/1048576',
    'db_ctx_switches': 'rate(node_context_switches_total{machine="db"}[15s])',
    'db_disk_write_mb_s': 'sum(rate(node_disk_written_bytes_total{machine="db"}[15s]))/1048576',
    'db_disk_iops': 'sum(rate(node_disk_writes_completed_total{machine="db"}[15s]))+sum(rate(node_disk_reads_completed_total{machine="db"}[15s]))',
    'db_net_rx_mb_s': 'sum(rate(node_network_receive_bytes_total{machine="db",device="eth1"}[15s]))/1048576',
    'db_net_tx_mb_s': 'sum(rate(node_network_transmit_bytes_total{machine="db",device="eth1"}[15s]))/1048576',
    # database internals; each database fills its own names
    'pg_connections': 'sum(pg_stat_activity_count{datname="shop"})', 'pg_active': 'sum(pg_stat_activity_count{datname="shop",state="active"})',
    'pg_commits_s': 'rate(pg_stat_database_xact_commit{datname="shop"}[15s])',
    'pg_cache_hit_pct': '100*rate(pg_stat_database_blks_hit{datname="shop"}[15s])/(rate(pg_stat_database_blks_hit{datname="shop"}[15s])+rate(pg_stat_database_blks_read{datname="shop"}[15s]))',
    'pg_deadlocks': 'pg_stat_database_deadlocks{datname="shop"}', 'pg_temp_bytes_s': 'rate(pg_stat_database_temp_bytes{datname="shop"}[15s])',
    'my_connections': 'mysql_global_status_threads_connected', 'my_running': 'mysql_global_status_threads_running',
    'my_commits_s': 'rate(mysql_global_status_commands_total{command="commit"}[15s])', 'my_queries_s': 'rate(mysql_global_status_queries[15s])',
    'my_cache_hit_pct': '100*(1-rate(mysql_global_status_innodb_buffer_pool_reads[15s])/rate(mysql_global_status_innodb_buffer_pool_read_requests[15s]))',
    'my_redo_mb_s': 'rate(mysql_global_status_innodb_os_log_written[15s])/1048576', 'my_row_lock_waits_s': 'rate(mysql_global_status_innodb_row_lock_waits[15s])',
    'pool_in_use': 'shop_db_in_use', 'pool_wait_s_per_s': 'rate(shop_db_wait_seconds_total[15s])',
}
for m in ('db', 'app', 'load'):
    for mode in ('user', 'system', 'iowait', 'steal', 'softirq', 'idle'):
        Q[f'{m}_cpu_{mode}'] = cpu(m, mode)
# the database is pinned to core 0 of its machine, so that core alone tells whether the database is the limit
for mode in ('user', 'system', 'iowait', 'softirq', 'idle'):
    Q[f'db_core0_{mode}'] = f'rate(node_cpu_seconds_total{{machine="db",cpu="0",mode="{mode}"}}[15s])*100'
out = {'start': T0, 'end': T1, 'step': 5, 'series': {}}
for name, expr in Q.items():
    u = 'http://127.0.0.1:9090/api/v1/query_range?' + urllib.parse.urlencode({'query': expr, 'start': T0, 'end': T1, 'step': 5})
    r = json.load(urllib.request.urlopen(u))['data']['result']
    out['series'][name] = [[int(float(t)) - T0, round(float(v), 3)] for t, v in r[0]['values'] if v != 'NaN'] if r else []
json.dump(out, sys.stdout)
