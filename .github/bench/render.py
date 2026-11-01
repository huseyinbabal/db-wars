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
    runs = {}
    for r in data['rows']:
        if NAME.match(r['db']) and r['version'] in ('base', 'pr'):
            runs.setdefault(r['db'], {}).setdefault(r['version'], []).append(r)
    rows = {db: {v: merge(rs) for v, rs in vs.items()} for db, vs in runs.items()}
    return data['folder'], int(data['pr']), data['k6_changed'] is True, rows

def merge(rs):
    """Both runs of one version: the mean for the table, the runs for the comparison. A failed run doesn't count."""
    good = [r for r in rs if r.get('status') in (0, 99)]
    out = {'stopped': any(r.get('status') == 99 for r in good), 'error': not good, 'runs': {}}
    for k in ('rps', 'p95', 'p99', 'failed'):
        vals = [v for v in (number(r.get(k)) for r in good) if v is not None]
        out['runs'][k] = vals; out[k] = sum(vals) / len(vals) if vals else None
    return out

def val(r, k, f='{:,.0f}'):
    if not r: return '–'
    if r['error'] or r[k] is None: return 'error'
    return f.format(r[k])

NOISE = {'rps': 5, 'p95': 25}   # percent; smaller changes can come from the runner alone

def delta(b, p, k, higher_is_better):
    """The arrow says which way the number moved, the colour whether that is good. Grey unless every PR run landed on the same side of every base run."""
    if not b or not p or not b[k] or p[k] is None or b['error'] or p['error']: return '–'
    change = (p[k] - b[k]) / b[k] * 100
    apart = min(p['runs'][k]) > max(b['runs'][k]) or max(p['runs'][k]) < min(b['runs'][k])
    if abs(change) < NOISE[k] or not apart: return f'⚪ {change:+.0f}%'
    return f'{"🟢" if (change > 0) == higher_is_better else "🔴"} {"▲" if change > 0 else "▼"} {abs(change):.0f}%'

def table(folder, changed, rows):
    out = [f'### `{folder}`', '', '| Database | req/s base | req/s PR | change | p95 ms base | p95 ms PR | change | p99 ms PR | failed PR |', '| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |']
    for db, v in rows.items():
        b, p = v.get('base'), v.get('pr')
        stop = ' (stopped early)' if p and p['stopped'] else ''
        out.append(f'| {db} | {val(b, "rps")} | {val(p, "rps")}{stop} | {delta(b, p, "rps", True)} | {val(b, "p95", "{:,.1f}")} | {val(p, "p95", "{:,.1f}")} | {delta(b, p, "p95", False)} | {val(p, "p99", "{:,.1f}")} | {val(p, "failed", "{:.2f}%")} |')
    if changed: out += ['', 'The k6 script changed in this PR, so base and PR did not get the same load.']
    return out + published(folder)

def published(folder):
    """The results from dedicated machines, for reference. A runner can't be compared with them."""
    try: data = json.load(open(f'{folder}/results/published.json'))
    except OSError: return []
    dbs = list(data['rounds'][0]['values'])
    out = ['', f'<details><summary>Published results ({data["metric"]})</summary>', '', data['machines'] + '.', '', '| Round | Runs | ' + ' | '.join(dbs) + ' |', '| --- | ---: |' + ' ---: |' * len(dbs)]
    out += [f'| {r["round"]} | {r["runs"]} | ' + ' | '.join(r['values'][d] for d in dbs) + ' |' for r in data['rounds']]
    return out + ['', '</details>']

results = [load(p) for p in sorted(glob.glob(f'{sys.argv[1]}/*.json'))]
pr = {r[1] for r in results}
if len(pr) != 1: sys.exit('results disagree on the PR number')
if '--pr' in sys.argv:
    print(pr.pop()); sys.exit()
body = ['<!-- bench -->', '## Bench', '', f'App, database and k6 share one GitHub runner, and each database runs base, PR, PR, base for about a minute each. The table shows the mean. 🟢 is better, 🔴 is worse, ⚪ is no clear change: the runs overlap, or the change is under {NOISE["rps"]}% for req/s or {NOISE["p95"]}% for p95. These numbers only compare base with PR.', '']
for folder, _, changed, rows in results:
    body += table(folder, changed, rows) + ['']
print('\n'.join(body))
