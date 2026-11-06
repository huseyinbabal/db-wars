#!/usr/bin/env python3
"""Pull one round's series for both databases from Prometheus: series2.py <prom url> <start> <end> <swap 0|1>"""
import json, sys, urllib.parse, urllib.request
URL, T0, T1, SWAP = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4] == '1'
stack = {'postgres': 'my' if SWAP else 'pg', 'mysql': 'pg' if SWAP else 'my'}
def q(db):
    s = stack[db]; k = f'db="{db}"'
    cpu = lambda m, mode: f'avg(rate(node_cpu_seconds_total{{stack="{s}",machine="{m}",mode="{mode}"}}[10s]))*100'
    d = {
        'rps': f'sum(rate(k6_http_reqs_total{{{k}}}[10s]))',
        'p50_ms': f'histogram_quantile(0.5,sum(rate(k6_http_req_duration_seconds{{{k}}}[10s])))*1000',
        'p95_ms': f'histogram_quantile(0.95,sum(rate(k6_http_req_duration_seconds{{{k}}}[10s])))*1000',
        'p99_ms': f'histogram_quantile(0.99,sum(rate(k6_http_req_duration_seconds{{{k}}}[10s])))*1000',
        'fail_rate': f'sum(rate(k6_http_req_failed_rate{{{k}}}[10s]))',
        'db_mem_used_mb': f'(node_memory_MemTotal_bytes{{stack="{s}",machine="db"}}-node_memory_MemAvailable_bytes{{stack="{s}",machine="db"}})/1048576',
        'db_disk_write_mb_s': f'sum(rate(node_disk_written_bytes_total{{stack="{s}",machine="db"}}[10s]))/1048576',
        'db_disk_read_mb_s': f'sum(rate(node_disk_read_bytes_total{{stack="{s}",machine="db"}}[10s]))/1048576',
        'db_disk_iops': f'sum(rate(node_disk_writes_completed_total{{stack="{s}",machine="db"}}[10s]))+sum(rate(node_disk_reads_completed_total{{stack="{s}",machine="db"}}[10s]))',
        'db_load1': f'node_load1{{stack="{s}",machine="db"}}',
    }
    for m in ('db', 'app', 'load'):
        for mode in ('user', 'system', 'iowait', 'steal', 'softirq', 'idle'):
            d[f'{m}_cpu_{mode}'] = cpu(m, mode)
    return d
out = {'start': T0, 'end': T1, 'step': 1, 'series': {}}
for db in ('postgres', 'mysql'):
    for name, expr in q(db).items():
        u = URL + '/api/v1/query_range?' + urllib.parse.urlencode({'query': expr, 'start': T0, 'end': T1, 'step': 1})
        r = json.load(urllib.request.urlopen(u))['data']['result']
        out['series'][f'{db}.{name}'] = [[int(float(t)) - T0, round(float(v), 3)] for t, v in r[0]['values'] if v != 'NaN'] if r else []
json.dump(out, sys.stdout)
