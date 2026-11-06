#!/usr/bin/env bash
# App machine: shop as a systemd unit, one env file per database (binary already at /usr/local/bin/shop).
#   DB_IP=... APP_IP=... PG_PW=... MY_PW=... bash app.sh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cloud-init status --wait >/dev/null || true
apt-get update -qq; apt-get install -y -qq sysstat prometheus-node-exporter postgresql-client mysql-client >/dev/null
sed -i "s|^ARGS=.*|ARGS=\"--web.listen-address=$APP_IP:9100\"|" /etc/default/prometheus-node-exporter; systemctl restart prometheus-node-exporter
cat > /etc/systemd/system/shop.service <<UNIT
[Unit]
Description=shop order service
After=network-online.target
[Service]
EnvironmentFile=/etc/shop.env
ExecStart=/usr/local/bin/shop
Restart=on-failure
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
UNIT
umask 077
printf 'DB_KIND=postgres\nDB_DSN=postgres://shop:%s@%s:5432/shop?sslmode=disable\nADDR=%s:8000\nDB_MAX_OPEN=100\n' "$PG_PW" "$DB_IP" "$APP_IP" > /etc/shop-postgres.env
printf 'DB_KIND=mysql\nDB_DSN=shop:%s@tcp(%s:3306)/shop?parseTime=true&cte_max_recursion_depth=1000000\nADDR=%s:8000\nDB_MAX_OPEN=100\n' "$MY_PW" "$DB_IP" "$APP_IP" > /etc/shop-mysql.env
systemctl daemon-reload; echo app ready
