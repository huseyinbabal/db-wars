#!/usr/bin/env bash
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
      - {targets: ["$DB_IP:9100"], labels: {machine: db}}
      - {targets: ["$APP_IP:9100"], labels: {machine: app}}
      - {targets: ["$LOAD_IP:9100"], labels: {machine: load}}
  - job_name: kv
    static_configs:
      - {targets: ["$DB_IP:9121"], labels: {machine: db}}
YML
sed -i "s|^ARGS=.*|ARGS=\"--web.listen-address=$MON_IP:9090 --web.enable-remote-write-receiver --enable-feature=native-histograms --storage.tsdb.retention.time=30d\"|" /etc/default/prometheus
sed -i 's|^;http_addr =.*|http_addr = 127.0.0.1|' /etc/grafana/grafana.ini
mkdir -p /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards /var/lib/grafana/dashboards
printf 'apiVersion: 1\ndatasources: [{name: prom, uid: prom, type: prometheus, url: "http://%s:9090", isDefault: true, jsonData: {timeInterval: 5s}}]\n' "$MON_IP" > /etc/grafana/provisioning/datasources/prom.yaml
printf 'apiVersion: 1\nproviders: [{name: files, type: file, options: {path: /var/lib/grafana/dashboards}}]\n' > /etc/grafana/provisioning/dashboards/files.yaml
printf '[auth.anonymous]\nenabled = true\norg_role = Viewer\n' >> /etc/grafana/grafana.ini
sed -i '0,/^\[dashboards\]/s//[dashboards]\nmin_refresh_interval = 1s/' /etc/grafana/grafana.ini
systemctl restart prometheus; systemctl enable -q --now grafana-server; systemctl restart grafana-server
prometheus --version 2>&1 | head -1
