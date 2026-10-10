#!/usr/bin/env bash
# Load machine: k6, Prometheus and Grafana from their package repositories. Nothing here listens on a public address.
#   DB_IP=... APP_IP=... bash load.sh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cloud-init status --wait >/dev/null || true
apt-get update -qq; apt-get install -y -qq gnupg curl sysstat prometheus >/dev/null 2>&1
curl -fsSL https://dl.k6.io/key.gpg | gpg --dearmor -o /usr/share/keyrings/k6-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" > /etc/apt/sources.list.d/k6.list
mkdir -p /etc/apt/keyrings; curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
apt-get update -qq; apt-get install -y -qq k6 grafana >/dev/null 2>&1
cat > /etc/prometheus/prometheus.yml <<YML
global:
  scrape_interval: 5s
scrape_configs:
  - job_name: node
    static_configs:
      - {targets: ["$DB_IP:9100"], labels: {machine: db}}
      - {targets: ["$APP_IP:9100"], labels: {machine: app}}
      - {targets: ["127.0.0.1:9100"], labels: {machine: load}}
  - job_name: shop
    static_configs: [{targets: ["$APP_IP:8000"]}]
  - job_name: database
    static_configs: [{targets: ["$DB_IP:9187", "$DB_IP:9104"]}]
YML
sed -i 's|^ARGS=.*|ARGS="--web.listen-address=127.0.0.1:9090 --web.enable-remote-write-receiver --enable-feature=native-histograms"|' /etc/default/prometheus
sed -i 's|^ARGS=.*|ARGS="--web.listen-address=127.0.0.1:9100"|' /etc/default/prometheus-node-exporter
sed -i 's|^;http_addr =.*|http_addr = 127.0.0.1|' /etc/grafana/grafana.ini
systemctl restart prometheus prometheus-node-exporter; systemctl enable -q --now grafana-server
k6 version | head -1
