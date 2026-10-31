#!/usr/bin/env bash
# App machine: docshop as a systemd unit, one env file per database (binary already at /usr/local/bin/docshop).
#   DB_IP=... APP_IP=... PG_PW=... MG_PW=... bash app.sh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cloud-init status --wait >/dev/null || true
apt-get update -qq; apt-get install -y -qq sysstat prometheus-node-exporter >/dev/null
sed -i "s|^ARGS=.*|ARGS=\"--web.listen-address=$APP_IP:9100\"|" /etc/default/prometheus-node-exporter; systemctl restart prometheus-node-exporter
cat > /etc/systemd/system/docshop.service <<UNIT
[Unit]
Description=docshop order service
After=network-online.target
[Service]
EnvironmentFile=/etc/docshop.env
ExecStart=/usr/local/bin/docshop
Restart=on-failure
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
UNIT
umask 077
printf 'DB_KIND=postgres\nDB_DSN=postgres://shop:%s@%s:5432/shop?sslmode=disable\nADDR=%s:8000\nDB_MAX_OPEN=100\n' "$PG_PW" "$DB_IP" "$APP_IP" > /etc/docshop-postgres.env
printf 'DB_KIND=mongo\nDB_DSN=mongodb://shop:%s@%s:27017/shop?authSource=admin&w=1&journal=true\nADDR=%s:8000\nDB_MAX_OPEN=100\n' "$MG_PW" "$DB_IP" "$APP_IP" > /etc/docshop-mongo.env
systemctl daemon-reload; echo app ready
