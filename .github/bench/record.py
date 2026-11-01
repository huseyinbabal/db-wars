#!/usr/bin/env python3
"""Keeps the bench numbers of a merged PR for the site: record.py <artifact dir> <pr json> <out dir>.
Only validated names and numbers go through. A PR whose test changed has no numbers (guard.py) and isn't recorded by the workflow."""
import glob, json, re, sys
NAME = re.compile(r'^[a-z0-9][a-z0-9.-]{0,63}$')
results_dir, pr_path, out = sys.argv[1:]
pr = json.load(open(pr_path))
num = lambda v: float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) and v >= 0 else None
results = []
for p in sorted(glob.glob(f'{results_dir}/*.json')):
    d = json.load(open(p))
    if not NAME.match(d['folder']): continue
    dbs = {}
    for r in d['rows']:
        if NAME.match(r['db']) and r['version'] in ('base', 'pr') and r.get('status') in (0, 99):
            dbs.setdefault(r['db'], {})[r['version']] = {'rps': num(r.get('rps')), 'p95': num(r.get('p95'))}
    results.append({'folder': d['folder'], 'dbs': dbs})
if results:
    json.dump({'pr': int(pr['number']), 'title': pr['title'], 'author': pr['user']['login'], 'merged_at': pr['merged_at'], 'results': results}, open(f'{out}/{int(pr["number"])}.json', 'w'), indent=1)
    print('recorded', pr['number'])
