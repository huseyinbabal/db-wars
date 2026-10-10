#!/usr/bin/env bash
# App machine: the Go service as a systemd unit, one env file per database.
#   DB_IP=... APP_IP=... PG_PW=... MY_PW=... bash app.sh   (binary already at /usr/local/bin/shop)
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cloud-init status --wait >/dev/null || true
apt-get update -qq; apt-get install -y -qq sysstat prometheus-node-exporter >/dev/null
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
printf 'DB_KIND=postgres\nDB_DSN=postgres://shop:%s@%s:5432/shop?sslmode=disable\nADDR=%s:8000\nDB_MAX_OPEN=100\nDB_POOL=on\n' "$PG_PW" "$DB_IP" "$APP_IP" > /etc/shop-postgres.env
printf 'DB_KIND=mariadb\nDB_DSN=shop:%s@tcp(%s:3306)/shop?parseTime=true\nADDR=%s:8000\nDB_MAX_OPEN=100\nDB_POOL=on\n' "$MY_PW" "$DB_IP" "$APP_IP" > /etc/shop-mariadb.env
systemctl daemon-reload; echo app ready
