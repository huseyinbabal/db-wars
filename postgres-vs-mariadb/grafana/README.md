# Grafana panels after the machines are gone

During a run, k6 writes its metrics to Prometheus on the load machine, and Grafana runs next to it.
The machines are deleted after every session, so what stays is `results/<run>/series.json`:
5-second query results pulled from that Prometheus by `series.py`.

To draw those series in Grafana again on a laptop:

1. Convert the series to OpenMetrics (`bench_requests_per_second`, `bench_p95_ms`, `bench_db_cpu_busy_percent`, labels `db` and `test`)
   and load them: `promtool tsdb create-blocks-from openmetrics data.om <tsdb dir>`
2. `prometheus --storage.tsdb.path=<tsdb dir> --storage.tsdb.retention.time=10y --web.listen-address=127.0.0.1:9391`
3. Start Grafana with the dashboards in `dashboards/` provisioned and a Prometheus datasource with uid `prom`.
4. `node shot.cjs <out dir>` takes 1920x1080 kiosk screenshots.

Postgres panels use a panel time shift so both databases fit on one dashboard (Postgres on top, MariaDB below).
Only the read dashboard has CPU panels: the other runs have gaps in the CPU samples, and a line drawn over a gap would be misleading.
