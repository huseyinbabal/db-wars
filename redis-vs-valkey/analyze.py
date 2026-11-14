#!/usr/bin/env python3
"""Per-step numbers for every run, straight from Prometheus (k6 remote write) and the run's own files.
  python3 analyze.py            -> results/summary.json + a table
A step is 5 s ramp + 30 s hold; each step is measured over its last 25 s."""
import json, os, subprocess, statistics, glob, re
D = os.path.dirname(os.path.abspath(__file__)); R = f'{D}/results'
env = dict(l.strip().split('=', 1) for l in open(f'{D}/run/hosts.env') if '=' in l)
MON = env['KV_MON_IP']
import os as _o
START, STEP, STEPS, RAMP, HOLD = [int(x) for x in _o.environ.get("STEPS_CFG", "10000 5000 8 5 30").split()]

def q(expr, t):
    cmd = f"curl -s 'http://{MON}:9090/api/v1/query' --data-urlencode 'query={expr}' --data-urlencode time={t}"
    out = subprocess.run(['ssh', '-F', f'{D}/run/ssh_config', 'kv-mon', cmd], capture_output=True, text=True).stdout
    r = json.loads(out)['data']['result']
    return float(r[0]['value'][1]) if r else None

def threads(path, t0, t1):
    """average %CPU per thread name from pidstat -t, inside [t0, t1] (HH:MM:SS UTC)"""
    s, n = {}, {}
    for line in open(path):
        p = line.split()
        if len(p) < 11 or p[0] in ('#', 'Linux') or p[3] == '-' or p[3] == 'TID': continue
        if not (t0 <= p[0] <= t1): continue
        name = p[-1].replace('|__', ''); s[name] = s.get(name, 0) + float(p[8]); n[name] = n.get(name, 0) + 1
    return {k: round(s[k] / n[k], 1) for k in s if s[k] / n[k] >= 1}

def mem(path):
    t = open(path).read()
    g = lambda k: int(re.search(rf'^{k}:(\d+)', t, re.M).group(1))
    return {'used_memory': g('used_memory'), 'dataset': g('used_memory_dataset'), 'overhead': g('used_memory_overhead')}

S = {}
for run in sorted(glob.glob(f'{R}/' + _o.environ.get('RUNS', 'io*-r*'))):
    name = os.path.basename(run)
    for kind in ('redis', 'valkey'):
        d = f'{run}/{kind}'
        if not os.path.exists(f'{d}/summary.json'): continue
        t0 = int(open(f'{d}/start').read())
        sm = json.load(open(f'{d}/summary.json'))['metrics']
        steps = []
        for i in range(STEPS):
            te = t0 + (i + 1) * (RAMP + HOLD)
            sel = f'{{kv="{kind}",run="{name}"}}'
            rps = q(f'sum(rate(k6_http_reqs_total{sel}[25s]))', te)
            p95 = q(f'histogram_quantile(0.95, sum(rate(k6_http_req_duration_seconds{sel}[25s])))', te)
            ops = q('sum(rate(redis_commands_processed_total[25s]))', te)
            fail = q(f'sum(rate(k6_http_req_failed_total{sel}[25s]))', te)
            steps.append({'target': START + i * STEP, 'rps': rps and round(rps), 'p95_ms': p95 and round(p95 * 1000, 1), 'ops': ops and round(ops)})
        best = max((s for s in steps if s['rps']), key=lambda s: s['rps'])
        hhmm = lambda t: subprocess.run(['date', '-u', '-r', str(t), '+%H:%M:%S'], capture_output=True, text=True).stdout.strip()
        bi = steps.index(best); be = t0 + (bi + 1) * (RAMP + HOLD)
        S.setdefault(name, {})[kind] = {
            'steps': steps, 'peak_rps': best['rps'], 'peak_target': best['target'], 'peak_p95_ms': best['p95_ms'], 'peak_ops': best['ops'],
            'requests': sm['http_reqs']['count'], 'failed_rate': sm['http_req_failed']['value'],
            'threads_at_peak': threads(f'{d}/pidstat.log', hhmm(be - 25), hhmm(be)),
            'memory_seeded': mem(f'{d}/memory-seeded.txt'),
            'server': open(f'{d}/server.txt').read().split('\n')[0]}
json.dump(S, open(f'{R}/summary.json', 'w'), indent=1)
for name in S:
    for kind in S[name]:
        x = S[name][kind]
        print(f"{name:8} {kind:6} peak {x['peak_rps']:>6} req/s @target {x['peak_target']:>6}  p95 {x['peak_p95_ms']} ms  ops {x['peak_ops']}  mem {x['memory_seeded']['used_memory']/2**20:.1f} MiB  threads {x['threads_at_peak']}")
