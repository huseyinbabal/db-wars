#!/usr/bin/env python3
"""Per-step table for both databases from results/<round>/series.json, and the sustained throughput:
the highest step that holds p95 < 50 ms with under 1% errors. usage: steps2.py <dir> <START> <STEP> <HOLD like 30s>"""
import json, sys
d = json.load(open(sys.argv[1] + '/series.json'))['series']; START, STEP, HOLD = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4].rstrip('s'))
LEN = HOLD + 5
def avg(n, a, b):
    v = [x for t, x in d.get(n, []) if a <= t < b]; return sum(v) / len(v) if v else float('nan')
res = {}
for db in ('postgres', 'sqlite'):
    rows, best = [], None
    print(f"\n{db}\n{'target':>7} {'rps':>6} {'p50':>7} {'p95':>8} {'p99':>8} {'fail%':>6} | db usr sys wait steal idle | app idle | load idle")
    last = max((t for t, _ in d.get(f'{db}.rps', [[0, 0]])), default=0)
    i = 0
    while (i + 1) * LEN <= last + 5:
        a, b = i * LEN + 12, (i + 1) * LEN   # skip the climb and the 10 s rate window
        g = lambda n: avg(f'{db}.{n}', a, b)
        row = dict(target=START + i * STEP, rps=g('rps'), p50=g('p50_ms'), p95=g('p95_ms'), p99=g('p99_ms'), fail=g('fail_rate') * 100,
                   usr=g('db_cpu_user'), sys=g('db_cpu_system') + g('db_cpu_softirq'), wait=g('db_cpu_iowait'), steal=g('db_cpu_steal'),
                   idle=g('db_cpu_idle'), app_idle=g('db_cpu_idle'), load_idle=g('load_cpu_idle'))
        print(f"{row['target']:>7} {row['rps']:>6.0f} {row['p50']:>7.2f} {row['p95']:>8.2f} {row['p99']:>8.2f} {row['fail']:>6.2f} |"
              f" {row['usr']:>6.0f} {row['sys']:>3.0f} {row['wait']:>4.0f} {row['steal']:>5.1f} {row['idle']:>4.0f} | {row['app_idle']:>8.0f} | {row['load_idle']:>9.0f}")
        if row['p95'] < 50 and row['fail'] < 1 and row['rps'] > 0.9 * row['target']: best = row
        rows.append(row); i += 1
    print('sustained throughput (p95 < 50 ms, < 1% errors):', f"{best['rps']:.0f} req/s at p95 {best['p95']:.1f} ms" if best else 'none')
    res[db] = dict(steps=rows, sustained=best)
json.dump(res, open(sys.argv[1] + '/steps.json', 'w'), indent=1)
