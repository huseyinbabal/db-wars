#!/usr/bin/env python3
"""Table per user level from results/<name>/series.json.
usage: stages.py <results dir> <users like 100,200,400> <HOLD seconds>"""
import json, sys
d = json.load(open(sys.argv[1] + '/series.json'))['series']; USERS = [int(x) for x in sys.argv[2].split(',')]; HOLD = int(sys.argv[3])
LEN = HOLD + 10                           # 10 s for the new users to arrive, then the hold
def avg(name, a, b):
    v = [x for t, x in d.get(name, []) if a <= t < b]; return sum(v) / len(v) if v else float('nan')
def top(name, a, b):
    v = [x for t, x in d.get(name, []) if a <= t < b]; return max(v) if v else float('nan')
print(f"{'users':>6} {'req/s':>6} {'p50':>7} {'p95':>8} {'p99':>8} {'fail%':>6} | db cpu: {'usr':>4} {'sys':>4} {'wait':>4} {'idle':>4} {'load':>5} {'mem MB':>7} {'conns':>5} | app idle | load idle")
for i, u in enumerate(USERS):
    a, b = i * LEN + 30, (i + 1) * LEN     # skip the arrival and the 15 s rate window
    conns = avg('pg_connections', a, b); conns = avg('my_connections', a, b) if conns != conns else conns
    print(f"{u:>6} {avg('rps', a, b):>6.0f} {avg('p50_ms', a, b):>7.1f} {avg('p95_ms', a, b):>8.1f} {avg('p99_ms', a, b):>8.1f} {100 * avg('fail_rate', a, b):>6.2f} |         "
          f"{avg('db_cpu_user', a, b):>4.0f} {avg('db_cpu_system', a, b) + avg('db_cpu_softirq', a, b):>4.0f} {avg('db_cpu_iowait', a, b):>4.0f} {avg('db_cpu_idle', a, b):>4.0f} "
          f"{avg('db_load1', a, b):>5.1f} {top('db_mem_used_mb', a, b):>7.0f} {conns:>5.0f} | {avg('app_cpu_idle', a, b):>8.0f} | {avg('load_cpu_idle', a, b):>9.0f}")
