#!/usr/bin/env bash
# Database machine (c-2: 2 dedicated vCPU, 4 GiB). PostgreSQL 18 and MongoDB 8.2 from their own repositories, only one runs at a time.
# Same memory for each (1 GiB of its own cache, the OS page cache holds the rest), every write reaches the disk before it is acknowledged.
#   DB_IP=<private ip> APP_IP=<private ip> MON_IP=<private ip> PG_PW=... MG_PW=... bash db.sh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cloud-init status --wait >/dev/null || true
apt-get update -qq
apt-get install -y -qq postgresql-common sysstat prometheus-node-exporter curl gnupg >/dev/null
/usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y >/dev/null 2>&1
apt-get install -y -qq postgresql-18 prometheus-postgres-exporter >/dev/null
curl -fsSL https://pgp.mongodb.com/server-8.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-server-8.2.gpg   # the 8.2 repo is signed with the 8.0 key
echo "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.2.gpg] https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/8.2 multiverse" > /etc/apt/sources.list.d/mongodb-org-8.2.list
MV=8.2.12   # not 8.2.0-8.2.2 (CVE-2025-14847)
apt-get update -qq; apt-get install -y -qq mongodb-org=$MV mongodb-org-database=$MV mongodb-org-server=$MV mongodb-org-mongos=$MV mongodb-org-tools=$MV mongodb-org-database-tools-extra=$MV mongodb-org-shell=$MV mongodb-mongosh >/dev/null
apt-mark hold mongodb-org mongodb-org-database mongodb-org-server >/dev/null

# PostgreSQL
C=/etc/postgresql/18/main
cat > $C/conf.d/bench.conf <<CONF
listen_addresses = 'localhost,$DB_IP'
max_connections = 200
shared_buffers = 1GB            # the database's own cache; the OS page cache holds the rest
effective_cache_size = 3GB
max_wal_size = 2GB
wal_level = minimal             # one machine, no replica, same as a standalone mongod without an oplog
max_wal_senders = 0
fsync = on
synchronous_commit = on         # a commit returns after its WAL is on disk, as MongoDB with j:true
ssl = off
CONF
echo "host shop shop $APP_IP/32 scram-sha-256" >> $C/pg_hba.conf
systemctl restart postgresql; sleep 3
sudo -u postgres psql -qc "CREATE ROLE shop LOGIN PASSWORD '$PG_PW'" -c "CREATE DATABASE shop OWNER shop" \
  -c "CREATE ROLE exporter LOGIN PASSWORD 'exporter'" -c "GRANT pg_monitor TO exporter"
sudo -u postgres psql -d shop -qc "CREATE EXTENSION pgstattuple" -c "GRANT ALL ON SCHEMA public TO shop"
printf 'DATA_SOURCE_NAME="postgresql://exporter:exporter@127.0.0.1:5432/shop?sslmode=disable"\nARGS="--web.listen-address=%s:9187"\n' "$DB_IP" > /etc/default/prometheus-postgres-exporter
systemctl restart prometheus-postgres-exporter
systemctl stop postgresql prometheus-postgres-exporter

# MongoDB: users first, then authorization on
cat > /etc/mongod.conf <<CONF
storage:
  dbPath: /var/lib/mongodb
  wiredTiger:
    engineConfig:
      cacheSizeGB: 1            # the database's own cache, as shared_buffers
systemLog: {destination: file, logAppend: true, path: /var/log/mongodb/mongod.log}
net: {port: 27017, bindIp: "127.0.0.1,$DB_IP"}
processManagement: {timeZoneInfo: /usr/share/zoneinfo}
CONF
systemctl start mongod; for i in $(seq 30); do mongosh --quiet --eval 1 >/dev/null 2>&1 && break; sleep 1; done
mongosh --quiet admin --eval "db.createUser({user:'shop',pwd:'$MG_PW',roles:[{role:'readWrite',db:'shop'},{role:'dbAdmin',db:'shop'}]});
  db.createUser({user:'exporter',pwd:'exporter',roles:['clusterMonitor',{role:'read',db:'local'}]})"
printf 'security:\n  authorization: enabled\n' >> /etc/mongod.conf
systemctl restart mongod; sleep 3; systemctl stop mongod
# Percona's exporter, the usual one for MongoDB
curl -fsSL -o /tmp/mx.json https://api.github.com/repos/percona/mongodb_exporter/releases/latest
V=$(grep -m1 '"tag_name"' /tmp/mx.json | cut -d'"' -f4)
curl -fsSL "https://github.com/percona/mongodb_exporter/releases/download/$V/mongodb_exporter-${V#v}.linux-amd64.tar.gz" | tar -xz -C /tmp
install /tmp/mongodb_exporter-${V#v}.linux-amd64/mongodb_exporter /usr/bin/mongodb_exporter
cat > /etc/systemd/system/mongodb-exporter.service <<UNIT
[Unit]
Description=mongodb_exporter
[Service]
Environment=MONGODB_URI=mongodb://exporter:exporter@127.0.0.1:27017/admin
ExecStart=/usr/bin/mongodb_exporter --web.listen-address=$DB_IP:9216 --collect-all --compatible-mode
Restart=on-failure
UNIT
systemctl daemon-reload

sed -i "s|^ARGS=.*|ARGS=\"--web.listen-address=$DB_IP:9100\"|" /etc/default/prometheus-node-exporter; systemctl restart prometheus-node-exporter
# exporters must keep answering when the database takes every CPU cycle (else Prometheus gets no samples at the limit)
for u in prometheus-node-exporter prometheus-postgres-exporter mongodb-exporter; do mkdir -p /etc/systemd/system/$u.service.d; printf '[Service]\nNice=-15\nCPUWeight=1000\n' > /etc/systemd/system/$u.service.d/prio.conf; done
systemctl daemon-reload; systemctl restart prometheus-node-exporter
systemctl disable -q postgresql mongod prometheus-postgres-exporter 2>/dev/null || true
psql --version; mongod --version | head -1; mongodb_exporter --version 2>&1 | head -1; nproc; free -m | sed -n 2p; df -h / | tail -1
