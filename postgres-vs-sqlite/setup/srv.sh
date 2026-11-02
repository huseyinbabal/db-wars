#!/usr/bin/env bash
# Server machine (c-2: 2 dedicated vCPU, 4 GiB): PostgreSQL 18 from its own repository, the SQLite file under /var/lib/shop,
# the shop app as a systemd unit. Only one database is used at a time. Same memory for each: 1 GiB of the database's own cache,
# the OS page cache holds the rest; every commit reaches the disk before it is acknowledged (fsync on both).
#   SRV_IP=<private ip> bash srv.sh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cloud-init status --wait >/dev/null || true
apt-get update -qq
apt-get install -y -qq postgresql-common sysstat prometheus-node-exporter sqlite3 curl gnupg build-essential >/dev/null
/usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y >/dev/null 2>&1
apt-get install -y -qq postgresql-18 prometheus-postgres-exporter >/dev/null

C=/etc/postgresql/18/main
cat > $C/conf.d/bench.conf <<CONF
listen_addresses = ''           # Unix socket only: the app is on this machine
max_connections = 200
shared_buffers = 1GB            # the database's own cache; the OS page cache holds the rest
effective_cache_size = 3GB
max_wal_size = 2GB
wal_level = minimal             # one machine, no replica
max_wal_senders = 0
fsync = on
synchronous_commit = on         # a commit returns after its WAL is on disk, as SQLite with synchronous=FULL
ssl = off
CONF
systemctl restart postgresql; sleep 3
sudo -u postgres psql -qc "CREATE ROLE shop LOGIN" -c "CREATE DATABASE shop OWNER shop" -c "CREATE ROLE exporter LOGIN" -c "GRANT pg_monitor TO exporter"
sed -i 's/^local\s\+all\s\+all\s\+peer/local all all trust/' $C/pg_hba.conf      # local socket only, nothing listens on the network
systemctl reload postgresql
printf 'DATA_SOURCE_NAME="postgresql://exporter@/shop?host=/var/run/postgresql&sslmode=disable"\nARGS="--web.listen-address=%s:9187"\n' "$SRV_IP" > /etc/default/prometheus-postgres-exporter
systemctl restart prometheus-postgres-exporter
systemctl stop postgresql prometheus-postgres-exporter

mkdir -p /var/lib/shop
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
# the same pool of 100 connections on both; SQLite: write-ahead log, fsync on every commit, 5 s wait for the write lock, 10 MiB cache per connection (x 100 connections = 1 GiB, as Postgres shared_buffers)
printf 'DB_KIND=postgres\nDB_DSN=postgres://shop@/shop?host=/var/run/postgresql&sslmode=disable\nADDR=%s:8000\nDB_MAX_OPEN=100\n' "$SRV_IP" > /etc/shop-postgres.env
printf 'DB_KIND=sqlite\nDB_DSN=file:/var/lib/shop/shop.db?_journal_mode=WAL&_synchronous=FULL&_busy_timeout=5000&_cache_size=-10240\nADDR=%s:8000\nDB_MAX_OPEN=100\n' "$SRV_IP" > /etc/shop-sqlite.env

sed -i "s|^ARGS=.*|ARGS=\"--web.listen-address=$SRV_IP:9100\"|" /etc/default/prometheus-node-exporter
for u in prometheus-node-exporter prometheus-postgres-exporter; do mkdir -p /etc/systemd/system/$u.service.d; printf '[Service]\nNice=-15\nCPUWeight=1000\n' > /etc/systemd/system/$u.service.d/prio.conf; done
systemctl daemon-reload; systemctl restart prometheus-node-exporter
systemctl disable -q postgresql prometheus-postgres-exporter 2>/dev/null || true
psql --version; sqlite3 --version | cut -d' ' -f1; nproc; free -m | sed -n 2p; df -h / | tail -1
