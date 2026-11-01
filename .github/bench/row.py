#!/usr/bin/env python3
"""One result line from a k6 summary export: row.py <database> <base|pr> <summary.json> <exit status>. k6 exits 99 when a threshold stops the test early."""
import json, sys
db, version, path, status = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
out = {'db': db, 'version': version, 'status': status}
try:
    m = json.load(open(path))['metrics']
    d = m['http_req_duration']
    out.update(rps=round(m['http_reqs']['rate'], 1), p95=round(d['p(95)'], 2), p99=round(d['p(99)'], 2), failed=round(m['http_req_failed'].get('value', 0) * 100, 2))
except (OSError, KeyError, ValueError):
    pass
print(json.dumps(out))
