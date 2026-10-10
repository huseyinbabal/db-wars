#!/usr/bin/env bash
# Database machine (2 dedicated vCPU, 4 GiB): PostgreSQL 18 and MariaDB 12.3 from their own repositories, only one running at a time.
# Settings are written out for both, so nothing depends on a default: same durability, same isolation level, no TLS, no replication log.
#   DB_IP=<private ip> APP_IP=<private ip> PG_PW=... MY_PW=... bash db.sh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cloud-init status --wait >/dev/null || true
apt-get update -qq
apt-get install -y -qq postgresql-common sysstat prometheus-node-exporter curl >/dev/null
/usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y >/dev/null 2>&1
apt-get install -y -qq postgresql-18 prometheus-postgres-exporter >/dev/null
curl -fsSL https://r.mariadb.com/downloads/mariadb_repo_setup | bash -s -- --mariadb-server-version=mariadb-12.3 --skip-maxscale --skip-tools >/dev/null 2>&1
apt-get install -y -qq mariadb-server prometheus-mysqld-exporter >/dev/null 2>&1 || true

# PostgreSQL: listen on the private address, let the app machine in
C=/etc/postgresql/18/main
cat > $C/conf.d/bench.conf <<CONF
listen_addresses = 'localhost,$DB_IP'
max_connections = 200
shared_buffers = 1GB            # 25% of memory, the documented starting point; the OS page cache holds the rest
effective_cache_size = 3GB
max_wal_size = 2GB
wal_level = minimal             # single machine, no replica: same as MariaDB without a binary log
max_wal_senders = 0
fsync = on
synchronous_commit = on         # every commit reaches the disk, as innodb_flush_log_at_trx_commit = 1
default_transaction_isolation = 'read committed'
ssl = off
CONF
echo "host shop shop $APP_IP/32 scram-sha-256" >> $C/pg_hba.conf
systemctl stop mariadb; systemctl restart postgresql; sleep 3
sudo -u postgres psql -qc "CREATE ROLE shop LOGIN PASSWORD '$PG_PW'" -c "CREATE DATABASE shop OWNER shop" \
  -c "CREATE ROLE exporter LOGIN PASSWORD 'exporter'" -c "GRANT pg_monitor TO exporter"
printf 'DATA_SOURCE_NAME="postgresql://exporter:exporter@127.0.0.1:5432/shop?sslmode=disable"\nARGS="--web.listen-address=%s:9187"\n' "$DB_IP" > /etc/default/prometheus-postgres-exporter
systemctl stop postgresql

# MariaDB: same
cat > /etc/mysql/mariadb.conf.d/99-bench.cnf <<CONF
[mariadbd]
bind-address = $DB_IP
max_connections = 200
innodb_buffer_pool_size = 2560M   # InnoDB reads with O_DIRECT and has no OS cache behind it, so it gets the usual larger share
innodb_log_file_size = 2G
innodb_flush_log_at_trx_commit = 1
skip-log-bin
transaction-isolation = READ-COMMITTED
character-set-server = utf8mb4
CONF
systemctl restart mariadb; sleep 3
mariadb -e "CREATE DATABASE shop; CREATE USER 'shop'@'$APP_IP' IDENTIFIED BY '$MY_PW'; GRANT ALL ON shop.* TO 'shop'@'$APP_IP';
  CREATE USER 'prometheus'@'localhost' IDENTIFIED VIA unix_socket; GRANT PROCESS, REPLICATION CLIENT, SLAVE MONITOR, SELECT ON *.* TO 'prometheus'@'localhost';"
printf '[client]\nuser=prometheus\nsocket=/run/mysqld/mysqld.sock\n' > /etc/mysqld-exporter.cnf
echo "ARGS=\"--config.my-cnf=/etc/mysqld-exporter.cnf --web.listen-address=$DB_IP:9104\"" > /etc/default/prometheus-mysqld-exporter
systemctl stop mariadb

sed -i "s|^ARGS=.*|ARGS=\"--web.listen-address=$DB_IP:9100\"|" /etc/default/prometheus-node-exporter; systemctl restart prometheus-node-exporter
systemctl disable -q mariadb postgresql prometheus-mysqld-exporter prometheus-postgres-exporter 2>/dev/null || true
systemctl stop prometheus-mysqld-exporter prometheus-postgres-exporter 2>/dev/null || true
psql --version; mariadbd --version; nproc; free -m | sed -n 2p
