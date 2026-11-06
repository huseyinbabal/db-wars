#!/usr/bin/env bash
# Database machine (c-2: 2 dedicated vCPU, 4 GiB). PostgreSQL 18 and MySQL 9.7 LTS from their own repositories, only one runs at a time.
# Same durability and isolation level, no TLS, no replication log. Nothing that matters is left on a default.
#   DB_IP=<private ip> APP_IP=<private ip> PG_PW=... MY_PW=... bash db.sh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cloud-init status --wait >/dev/null || true
apt-get update -qq
apt-get install -y -qq postgresql-common sysstat prometheus-node-exporter curl gnupg >/dev/null
/usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y >/dev/null 2>&1
apt-get install -y -qq postgresql-18 prometheus-postgres-exporter >/dev/null
curl -fsSL https://repo.mysql.com/RPM-GPG-KEY-mysql-2025 | gpg --dearmor -o /usr/share/keyrings/mysql.gpg
echo "deb [signed-by=/usr/share/keyrings/mysql.gpg] http://repo.mysql.com/apt/ubuntu noble mysql-9.7-lts" > /etc/apt/sources.list.d/mysql.list
apt-get update -qq
apt-get install -y -qq mysql-server prometheus-mysqld-exporter >/dev/null

# PostgreSQL
C=/etc/postgresql/18/main
cat > $C/conf.d/bench.conf <<CONF
listen_addresses = 'localhost,$DB_IP'
max_connections = 200
shared_buffers = 1GB            # 25% of memory, the documented starting point; the OS page cache holds the rest
effective_cache_size = 3GB
max_wal_size = 2GB
wal_level = minimal             # one machine, no replica: same as MySQL without a binary log
max_wal_senders = 0
fsync = on
synchronous_commit = on         # every commit reaches the disk, as innodb_flush_log_at_trx_commit = 1
default_transaction_isolation = 'read committed'
ssl = off
CONF
echo "host shop shop $APP_IP/32 scram-sha-256" >> $C/pg_hba.conf
systemctl restart postgresql; sleep 3
sudo -u postgres psql -qc "CREATE ROLE shop LOGIN PASSWORD '$PG_PW'" -c "CREATE DATABASE shop OWNER shop" \
  -c "CREATE ROLE exporter LOGIN PASSWORD 'exporter'" -c "GRANT pg_monitor TO exporter"
printf 'DATA_SOURCE_NAME="postgresql://exporter:exporter@127.0.0.1:5432/shop?sslmode=disable"\nARGS="--web.listen-address=%s:9187"\n' "$DB_IP" > /etc/default/prometheus-postgres-exporter
systemctl stop postgresql prometheus-postgres-exporter

# MySQL
cat > /etc/mysql/mysql.conf.d/99-bench.cnf <<CONF
[mysqld]
bind-address = $DB_IP
mysqlx = OFF
max_connections = 200
innodb_buffer_pool_size = 2560M   # InnoDB reads with O_DIRECT and has no OS cache behind it, so it gets the usual larger share
innodb_flush_method = O_DIRECT
innodb_redo_log_capacity = 2G
innodb_flush_log_at_trx_commit = 1
skip-log-bin
transaction-isolation = READ-COMMITTED
character-set-server = utf8mb4
require_secure_transport = OFF
CONF
systemctl restart mysql; sleep 3
mysql -e "CREATE DATABASE shop; CREATE USER 'shop'@'$APP_IP' IDENTIFIED BY '$MY_PW'; GRANT ALL ON shop.* TO 'shop'@'$APP_IP';
  CREATE USER 'exporter'@'localhost' IDENTIFIED BY 'exporter'; GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'localhost';"
printf '[client]\nuser=exporter\npassword=exporter\nhost=127.0.0.1\n' > /etc/mysqld-exporter.cnf; chown prometheus /etc/mysqld-exporter.cnf; chmod 600 /etc/mysqld-exporter.cnf
sed -i "s/^bind-address.*/bind-address = 127.0.0.1,$DB_IP/" /etc/mysql/mysql.conf.d/99-bench.cnf
echo "ARGS=\"--config.my-cnf=/etc/mysqld-exporter.cnf --web.listen-address=$DB_IP:9104\"" > /etc/default/prometheus-mysqld-exporter
systemctl stop mysql prometheus-mysqld-exporter

sed -i "s|^ARGS=.*|ARGS=\"--web.listen-address=$DB_IP:9100\"|" /etc/default/prometheus-node-exporter; systemctl restart prometheus-node-exporter
# exporters must keep answering when the database takes every CPU cycle (else Prometheus gets no samples at the limit)
for u in prometheus-node-exporter prometheus-postgres-exporter prometheus-mysqld-exporter; do mkdir -p /etc/systemd/system/$u.service.d; printf '[Service]\nNice=-15\nCPUWeight=1000\n' > /etc/systemd/system/$u.service.d/prio.conf; done
systemctl daemon-reload; systemctl restart prometheus-node-exporter
systemctl disable -q postgresql mysql prometheus-postgres-exporter prometheus-mysqld-exporter 2>/dev/null || true
psql --version; mysqld --version; grep -m1 'model name' /proc/cpuinfo; nproc; free -m | sed -n 2p; df -h / | tail -1
