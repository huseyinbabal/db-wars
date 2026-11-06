#!/usr/bin/env python3
"""Side-by-side live dashboard: Postgres on the left, MySQL on the right, same panels and same axes.
   gen_dash.py <rps axis max> > live.json"""
import json, sys
RPS_MAX = float(sys.argv[1]) if len(sys.argv) > 1 else None
SIDES = [('postgres', 'pg', 'PostgreSQL 18', '#5B9BD5'), ('mysql', 'my', 'MySQL 9.7', '#3FD17A')]
panels, pid = [], 0
def add(p, x, y, w, h):
    global pid; pid += 1
    p.update(id=pid, gridPos=dict(x=x, y=y, w=w, h=h), datasource=dict(type='prometheus', uid='prom')); panels.append(p)
def ts(title, targets, unit, color, maxv=None, log=False, stack=False, minv=0):
    custom = dict(lineWidth=3, fillOpacity=12, showPoints='never', spanNulls=False, insertNulls=8000)   # a gap (data loading) stays a gap
    if log: custom['scaleDistribution'] = dict(type='log', log=10)
    if stack: custom.update(stacking=dict(mode='normal'), fillOpacity=55, lineWidth=1)
    d = dict(unit=unit, color=dict(mode='fixed', fixedColor=color), custom=custom, decimals=1 if unit == 'ms' else None)
    if not log: d['min'] = minv
    if maxv: d['max'] = maxv
    return dict(type='timeseries', title=title, targets=targets, fieldConfig=dict(defaults=d, overrides=[]),
                options=dict(legend=dict(showLegend=len(targets) > 1, displayMode='list', placement='bottom'), tooltip=dict(mode='none')))
def stat(title, expr, unit, color, dec):
    return dict(type='stat', title=title, targets=[dict(refId='A', expr=expr, instant=False)],
                fieldConfig=dict(defaults=dict(unit=unit, decimals=dec, color=dict(mode='fixed', fixedColor=color)), overrides=[]),
                options=dict(reduceOptions=dict(calcs=['lastNotNull']), colorMode='value', graphMode='area', textMode='value', justifyMode='center'))
for i, (db, s, name, color) in enumerate(SIDES):
    x = i * 12; k = f'db="{db}"'
    add(dict(type='text', title='', options=dict(mode='html', content=f'<div style="font-size:36px;font-weight:700;color:{color};text-align:center;line-height:1.5">{name}</div>'), transparent=True), x, 0, 12, 2)
    add(stat('requests / s', f'sum(rate(k6_http_reqs_total{{{k}}}[5s]))', 'reqps', color, 0), x, 2, 6, 4)
    add(stat('p95 response time', f'histogram_quantile(0.95,sum(rate(k6_http_req_duration_seconds{{{k}}}[5s])))*1000', 'ms', color, 1), x + 6, 2, 6, 4)
    add(ts('requests per second', [dict(refId='A', expr=f'sum(rate(k6_http_reqs_total{{{k}}}[5s]))', legendFormat='req/s')], 'reqps', color, RPS_MAX), x, 6, 12, 6)
    lat = [dict(refId=r, expr=f'histogram_quantile({q},sum(rate(k6_http_req_duration_seconds{{{k}}}[5s])))*1000', legendFormat=l)
           for r, q, l in (('A', 0.5, 'p50'), ('B', 0.95, 'p95'), ('C', 0.99, 'p99'))]
    p = ts('response time (log scale)', lat, 'ms', color, log=True)
    p['fieldConfig']['defaults']['color'] = dict(mode='palette-classic')
    p['fieldConfig']['overrides'] = [dict(matcher=dict(id='byName', options=n), properties=[dict(id='color', value=dict(mode='fixed', fixedColor=c))])
                                     for n, c in (('p50', '#9AA4B2'), ('p95', color), ('p99', '#F2A43A'))]
    add(p, x, 12, 12, 7)
    cpu = [dict(refId=chr(65 + j), expr=f'avg(rate(node_cpu_seconds_total{{stack="{s}",machine="db",mode="{m}"}}[15s]))*100', legendFormat=m)
           for j, m in enumerate(('user', 'system', 'iowait', 'steal'))]
    p = ts('database machine CPU %', cpu, 'percent', color, 100, stack=True)
    p['fieldConfig']['defaults']['color'] = dict(mode='palette-classic')
    p['fieldConfig']['overrides'] = [dict(matcher=dict(id='byName', options=n), properties=[dict(id='color', value=dict(mode='fixed', fixedColor=c))])
                                     for n, c in (('user', color), ('system', '#B877D9'), ('iowait', '#F2A43A'), ('steal', '#E02F44'))]
    add(p, x, 19, 12, 7)
json.dump(dict(uid='dbwars4-live', title='Database Wars 2 · live', timezone='utc', schemaVersion=39, refresh='1s',
               time={'from': 'now-3m', 'to': 'now'}, timepicker=dict(refresh_intervals=['1s', '2s', '5s', '10s']), panels=panels, style='dark'), sys.stdout, indent=1)
