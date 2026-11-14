# Grafana dashboard for one run: k6 rate and p95, server ops/s, server CPU by thread group, memory.
import json, sys
def ts(id_, title, expr, unit, x, y, w=12, h=9, legend='{{kv}}'):
    return {"id": id_, "type": "timeseries", "title": title, "datasource": {"type": "prometheus", "uid": "prom"},
            "gridPos": {"x": x, "y": y, "w": w, "h": h},
            "fieldConfig": {"defaults": {"unit": unit, "custom": {"lineWidth": 3, "fillOpacity": 12, "showPoints": "never", "spanNulls": True}}, "overrides": []},
            "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": True}, "tooltip": {"mode": "multi"}},
            "targets": [{"refId": "A", "expr": expr, "legendFormat": legend, "interval": "5s"}]}
P = [
  ts(1, "Requests per second (k6)", 'sum by (kv) (rate(k6_http_reqs_total[15s]))', "reqps", 0, 0),
  ts(2, "Latency p95 (k6)", 'histogram_quantile(0.95, sum by (kv) (rate(k6_http_req_duration_seconds[15s])))', "s", 12, 0),
  ts(3, "Server commands per second", 'sum(rate(redis_commands_processed_total[15s]))', "ops", 0, 9, legend="commands/s"),
  ts(4, "Database machine CPU (4 cores)", '100 * (1 - avg(rate(node_cpu_seconds_total{machine="db",mode="idle"}[15s])))', "percent", 12, 9, legend="cpu"),
  ts(5, "Memory used", 'redis_memory_used_bytes', "bytes", 0, 18, legend="used_memory"),
  ts(6, "Connected clients", 'redis_connected_clients', "short", 12, 18, legend="clients"),
]
d = {"uid": "kvwars", "title": "Redis vs Valkey", "time": {"from": "now-15m", "to": "now"}, "refresh": "", "schemaVersion": 39,
     "style": "dark", "panels": P, "timepicker": {"refresh_intervals": ["1s", "5s", "10s"]}}
print(json.dumps(d))
