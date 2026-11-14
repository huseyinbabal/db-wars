#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cloud-init status --wait >/dev/null || true
apt-get update -qq; apt-get install -y -qq sysstat prometheus-node-exporter >/dev/null 2>&1
sed -i "s|^ARGS=.*|ARGS=\"--web.listen-address=$APP_IP:9100\"|" /etc/default/prometheus-node-exporter; systemctl restart prometheus-node-exporter
cat > /etc/systemd/system/kvshop.service <<UNIT
[Unit]
Description=kvshop
After=network-online.target
[Service]
Environment=KV_ADDR=$DB_IP:6379 ADDR=$APP_IP:8000 KV_POOL=200
ExecStart=/usr/local/bin/kvshop
Restart=on-failure
LimitNOFILE=200000
[Install]
WantedBy=multi-user.target
UNIT
sysctl -qw net.ipv4.ip_local_port_range="1024 65000" net.ipv4.tcp_tw_reuse=1 net.core.somaxconn=65535
systemctl daemon-reload; echo app ready
