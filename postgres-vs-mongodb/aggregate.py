#!/usr/bin/env python3
"""Median of the repeated rounds: sustained throughput (highest step with p95 < 50 ms, < 1 % errors) and its p95, per database.
  aggregate.py   -> prints the table and writes results/summary.json"""
import glob, json, os, re, statistics
R = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'results')
FAM = {'reads': r'read-[123]$', 'inserts': r'insert-[345]$', 'updates': r'update-[123]$', 'shop (defaults)': r'shop-[123]$',
       'shop (fastupdate off)': r'shop-tuned-(1b|2|3)$', 'inserts (fastupdate off)': r'insert-tuned-[123]$',
       'big docs: updates': r'bigdoc-update-1$', 'big docs: reads': r'bigdoc-read-1$', 'shop (fastupdate off), hosts swapped': r'shop-tuned-swap$'}
out = {}
for fam, rx in FAM.items():
    runs = sorted(d for d in os.listdir(R) if re.fullmatch(rx, d) and os.path.exists(f'{R}/{d}/steps.json'))
    if not runs: continue
    row = {'runs': runs}
    for db in ('postgres', 'mongo'):
        s = [json.load(open(f'{R}/{d}/steps.json'))[db] for d in runs]
        sus = [x['sustained']['rps'] if x['sustained'] else 0 for x in s]
        top = [x['steps'][-1]['target'] if x['steps'] else 0 for x in s]          # last step reached: if it still held, the limit is above it
        held_top = [bool(x['sustained']) and x['sustained']['target'] == x['steps'][-1]['target'] for x in s]
        p95 = [x['sustained']['p95'] for x in s if x['sustained']]
        row[db] = dict(sustained=round(statistics.median(sus)), each=[round(v) for v in sus], p95=round(statistics.median(p95), 1) if p95 else None,
                       above_range=any(held_top), top=max(top))
    out[fam] = row
    f = lambda d: f"{d['sustained']:>6}{'+' if d['above_range'] else ' '} p95 {d['p95'] if d['p95'] is not None else '-':>5}  {d['each']}"
    print(f"{fam:38} pg {f(row['postgres'])}   mg {f(row['mongo'])}")
json.dump(out, open(f'{R}/summary.json', 'w'), indent=1)
print("'+' = still holding at the last step of the test, the limit is higher")
