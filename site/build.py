#!/usr/bin/env python3
"""The page at db-wars.huseyinbabal.dev: build.py <dir with merged/*.json> → site/dist/index.html.
Comparisons come from */results/published.json, merged PRs from record.py, so a new folder or a merge shows up by itself."""
import glob, html, json, os, re, shutil, sys
D = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(D); DATA = sys.argv[1] if len(sys.argv) > 1 else ''
NAMES = {'postgres': 'PostgreSQL', 'mongo': 'MongoDB', 'mariadb': 'MariaDB', 'sqlite': 'SQLite'}
NOISE = {'rps': 5, 'p95': 25}
esc = html.escape
num = lambda v: (lambda m: float(m.group().replace(',', '')) if m else None)(re.match(r'[\d,]+', v))

def logo(db): return f'<img src="logos/{db}.svg" alt="{NAMES.get(db, db)}">' if os.path.exists(f'{D}/logos/{db}.svg') else ''

def comparison(path):
    folder = os.path.basename(os.path.dirname(os.path.dirname(path))); d = json.load(open(path))
    dbs = list(d['rounds'][0]['values'])
    rounds = ''
    for r in d['rounds']:
        top = max([num(v) or 0 for v in r['values'].values()]) or 1
        bars = ''.join(f'<div class="bar"><span class="who">{esc(NAMES.get(db, db))}</span><span class="track"><i class="c{i}" style="width:{(num(r["values"][db]) or 0) / top * 100:.1f}%"></i></span><b>{esc(r["values"][db])}</b></div>' for i, db in enumerate(dbs))
        once = '<em>one run</em>' if r['runs'] == 1 else ''
        rounds += f'<div class="round"><h4>{esc(r["round"])} {once}</h4>{bars}</div>'
    video = f'<a href="{esc(d["video"])}">Video</a>' if d.get('video') else ''
    return (f'<article class="cmp"><header><div class="logos">{"<i>vs</i>".join(logo(db) for db in dbs)}</div><h3>{esc(d["title"])}</h3>'
            f'<p>{esc(d["machines"])}. Shown: {esc(d["metric"])}.</p><nav><a href="https://github.com/huseyinbabal/db-wars/tree/main/{esc(folder)}">Code and setup</a>{video}</nav></header>{rounds}</article>')

def change(b, p, k, higher):
    if not b or not p or not b.get(k) or p.get(k) is None: return '<td>–</td>'
    c = (p[k] - b[k]) / b[k] * 100
    if abs(c) < NOISE[k]: return f'<td class="flat">{c:+.0f}%</td>'
    return f'<td class="{"up" if (c > 0) == higher else "down"}">{"▲" if c > 0 else "▼"} {abs(c):.0f}%</td>'

def merged():
    rows = ''
    for m in sorted((json.load(open(p)) for p in glob.glob(f'{DATA}/merged/*.json')), key=lambda m: -m['pr']):
        for f in m['results']:
            for db, v in f['dbs'].items():
                rows += (f'<tr><td><a href="https://github.com/huseyinbabal/db-wars/pull/{m["pr"]}">#{m["pr"]}</a></td><td class="t">{esc(m["title"])}</td><td>{esc(m["author"])}</td><td>{esc(f["folder"])}</td><td>{esc(NAMES.get(db, db))}</td>'
                         + change(v.get('base'), v.get('pr'), 'rps', True) + change(v.get('base'), v.get('pr'), 'p95', False) + '</tr>')
    if not rows: return '<p class="empty">No merged PRs with numbers yet. The first one lands here when it merges.</p>'
    return f'<div class="scroll"><table><thead><tr><th>PR</th><th>Change</th><th>By</th><th>Comparison</th><th>Database</th><th>req/s</th><th>p95</th></tr></thead><tbody>{rows}</tbody></table></div>'

page = open(f'{D}/template.html').read()
paths = sorted(glob.glob(f'{ROOT}/*/results/published.json'))
page = page.replace('@@COMPARISONS@@', '\n'.join(comparison(p) for p in paths)).replace('@@MERGED@@', merged()).replace('@@COUNT@@', str(len(paths)))
os.makedirs(f'{D}/dist', exist_ok=True); open(f'{D}/dist/index.html', 'w').write(page)
shutil.copytree(f'{D}/logos', f'{D}/dist/logos', dirs_exist_ok=True)
print(f'{len(paths)} comparisons')
