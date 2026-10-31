#!/usr/bin/env bash
# Load machine: k6 only. Results go to Prometheus on the monitor machine by remote write.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cloud-init status --wait >/dev/null || true
apt-get update -qq; apt-get install -y -qq gnupg curl sysstat prometheus-node-exporter >/dev/null 2>&1
curl -fsSL https://dl.k6.io/key.gpg | gpg --dearmor -o /usr/share/keyrings/k6-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" > /etc/apt/sources.list.d/k6.list
apt-get update -qq; apt-get install -y -qq k6 >/dev/null 2>&1
sed -i "s|^ARGS=.*|ARGS=\"--web.listen-address=$LOAD_IP:9100\"|" /etc/default/prometheus-node-exporter; systemctl restart prometheus-node-exporter
sysctl -qw net.ipv4.ip_local_port_range="1024 65000" net.ipv4.tcp_tw_reuse=1
k6 version | head -1
