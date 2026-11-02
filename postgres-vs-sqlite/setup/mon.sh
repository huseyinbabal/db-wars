#!/usr/bin/env bash
# Monitor machine: Prometheus (scrapes both stacks, receives k6) and Grafana, both on the private address / localhost only.
#   PG_SRV_IP=.. SL_SRV_IP=.. PG_LOAD_IP=.. SL_LOAD_IP=.. MON_IP=.. bash mon.sh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cloud-init status --wait >/dev/null || true
apt-get update -qq; apt-get install -y -qq gnupg curl prometheus >/dev/null 2>&1
mkdir -p /etc/apt/keyrings; curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
apt-get update -qq; apt-get install -y -qq grafana >/dev/null 2>&1
cat > /etc/prometheus/prometheus.yml <<YML
global:
  scrape_interval: 5s
scrape_configs:
  - job_name: node
    static_configs:
      - {targets: ["$PG_SRV_IP:9100"], labels: {stack: pg, machine: db}}
      - {targets: ["$SL_SRV_IP:9100"], labels: {stack: sl, machine: db}}
      - {targets: ["$PG_LOAD_IP:9100"], labels: {stack: pg, machine: load}}
      - {targets: ["$SL_LOAD_IP:9100"], labels: {stack: sl, machine: load}}
  - job_name: database
    static_configs:
      - {targets: ["$PG_SRV_IP:9187"], labels: {stack: pg}}
      - {targets: ["$SL_SRV_IP:9187"], labels: {stack: sl}}
  - job_name: app
    static_configs:
      - {targets: ["$PG_SRV_IP:8000"], labels: {stack: pg}}
      - {targets: ["$SL_SRV_IP:8000"], labels: {stack: sl}}
YML
sed -i "s|^ARGS=.*|ARGS=\"--web.listen-address=$MON_IP:9090 --web.enable-remote-write-receiver --enable-feature=native-histograms --storage.tsdb.retention.time=30d\"|" /etc/default/prometheus
sed -i 's|^;http_addr =.*|http_addr = 127.0.0.1|' /etc/grafana/grafana.ini
mkdir -p /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards /var/lib/grafana/dashboards
cat > /etc/grafana/provisioning/datasources/prom.yaml <<YML
apiVersion: 1
datasources: [{name: prom, uid: prom, type: prometheus, url: "http://$MON_IP:9090", isDefault: true, jsonData: {timeInterval: 5s}}]
YML
cat > /etc/grafana/provisioning/dashboards/files.yaml <<YML
apiVersion: 1
providers: [{name: files, type: file, options: {path: /var/lib/grafana/dashboards}}]
YML
cat >> /etc/grafana/grafana.ini <<INI
[auth.anonymous]
enabled = true
org_role = Viewer
INI
sed -i '0,/^\[dashboards\]/s//[dashboards]\nmin_refresh_interval = 1s/' /etc/grafana/grafana.ini   # inside the existing section, a second one is ignored
systemctl restart prometheus; systemctl enable -q --now grafana-server; systemctl restart grafana-server
prometheus --version 2>&1 | head -1; grafana-server -v 2>/dev/null || grafana server -v
