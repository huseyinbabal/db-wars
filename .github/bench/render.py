#!/usr/bin/env python3
"""Markdown table from the result files of one PR: render.py <dir>. With --pr it prints only the PR number.
The files can come from a fork, so only names that match a strict pattern and real numbers reach the output."""
import glob, json, re, sys
NAME = re.compile(r'^[a-z0-9][a-z0-9.-]{0,63}$')

def number(v):
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) and v >= 0 else None

def load(path):
    data = json.load(open(path))
    if not NAME.match(data['folder']): raise ValueError('bad folder')
    rows = {}
    for r in data['rows']:
        if NAME.match(r['db']) and r['version'] in ('base', 'pr'):
            rows.setdefault(r['db'], {})[r['version']] = {k: number(r.get(k)) for k in ('rps', 'p95', 'p99', 'failed')} | {'stopped': r.get('status') == 99, 'error': r.get('status') not in (0, 99)}
    return data['folder'], int(data['pr']), data['k6_changed'] is True, rows

def val(r, k, f='{:,.0f}'):
    if not r: return '–'
    if r['error'] or r[k] is None: return 'error'
    return f.format(r[k])

def delta(b, p, k):
    if not b or not p or not b[k] or p[k] is None or b['error'] or p['error']: return '–'
    return f'{(p[k] - b[k]) / b[k] * 100:+.0f}%'

def table(folder, changed, rows):
    out = [f'### `{folder}`', '', '| Database | req/s base | req/s PR | change | p95 ms base | p95 ms PR | change | p99 ms PR | failed PR |', '| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |']
    for db, v in rows.items():
        b, p = v.get('base'), v.get('pr')
        stop = ' (stopped early)' if p and p['stopped'] else ''
        out.append(f'| {db} | {val(b, "rps")} | {val(p, "rps")}{stop} | {delta(b, p, "rps")} | {val(b, "p95", "{:,.1f}")} | {val(p, "p95", "{:,.1f}")} | {delta(b, p, "p95")} | {val(p, "p99", "{:,.1f}")} | {val(p, "failed", "{:.2f}%")} |')
    if changed: out += ['', 'The k6 script changed in this PR, so base and PR did not get the same load.']
    return out

results = [load(p) for p in sorted(glob.glob(f'{sys.argv[1]}/*.json'))]
pr = {r[1] for r in results}
if len(pr) != 1: sys.exit('results disagree on the PR number')
if '--pr' in sys.argv:
    print(pr.pop()); sys.exit()
body = ['<!-- bench -->', '## Bench', '', 'About a minute per run: app, database and k6 share one GitHub runner, base and PR one after the other. Compare the numbers with each other; they say nothing about real machines, and a change of a few percent can be noise.', '']
for folder, _, changed, rows in results:
    body += table(folder, changed, rows) + ['']
print('\n'.join(body))
