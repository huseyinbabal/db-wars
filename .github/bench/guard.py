#!/usr/bin/env python3
"""Checks what a PR changed, from GitHub's file list (one JSON object per line on stdin, with filename and patch).
Prints a note for the comment and exits 1 when the numbers must not be published. Runs from main, so a PR can't change it.
The app and ci/compose.yml are open to change, as long as every write still reaches the disk."""
import json, re, sys
LOCKED = re.compile(r'^(\.github/|[^/]+/k6/|[^/]+/ci/bench\.conf$|[^/]+/results/)')
COMPOSE = re.compile(r'^[^/]+/ci/compose\.yml$')
UNSAFE = re.compile(r'''fsync\s*=\s*(off|false|0)|synchronous[_-]commit\s*=\s*(off|local|false|0)|full[_-]page[_-]writes\s*=\s*(off|false|0)
    |flush[_-]log[_-]at[_-]trx[_-]commit\s*=\s*[02]|doublewrite\s*=\s*(off|false|0)|flush[_-]method\s*=\s*nosync|nojournal|tmpfs|/dev/shm''', re.I | re.X)
clean = lambda s: re.sub(r'[^A-Za-z0-9._/-]', '?', s)[:120]

locked, unsafe, compose = [], [], []
for line in sys.stdin:
    f = json.loads(line); name = f['filename']
    if LOCKED.match(name): locked.append(clean(name))
    if COMPOSE.match(name):
        compose.append(clean(name)); patch = f.get('patch')
        if patch is None or any(l.startswith('+') and UNSAFE.search(l) for l in patch.split('\n')): unsafe.append(clean(name))

if locked or unsafe:
    print('<!-- bench -->\n## Bench\n\nNo numbers for this PR, because the test itself changed.\n')
    for n in locked: print(f'- `{n}` is fixed: the load and the test have to stay the same for every PR.')
    for n in unsafe: print(f'- `{n}` turns off a durability setting or moves data to memory: every write has to reach the disk.')
    sys.exit(1)
for n in compose: print(f'`{n}` changed in this PR, so the PR column runs with those settings.\n')
