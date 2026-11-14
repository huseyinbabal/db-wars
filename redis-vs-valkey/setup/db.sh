#!/usr/bin/env bash
# Database machine: Docker with both images, node exporter, redis_exporter (works for both). Everything on the private address.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cloud-init status --wait >/dev/null || true
apt-get update -qq; apt-get install -y -qq docker.io sysstat prometheus-node-exporter >/dev/null 2>&1
sed -i "s|^ARGS=.*|ARGS=\"--web.listen-address=$DB_IP:9100\"|" /etc/default/prometheus-node-exporter; systemctl restart prometheus-node-exporter
docker pull -q redis:8.10.3-trixie; docker pull -q valkey/valkey:9.1.3-trixie
curl -fsSL https://github.com/oliver006/redis_exporter/releases/download/v1.97.0/redis_exporter-v1.97.0.linux-amd64.tar.gz | tar xz -C /tmp
install /tmp/redis_exporter-v1.97.0.linux-amd64/redis_exporter /usr/local/bin/
cat > /etc/systemd/system/kv-exporter.service <<UNIT
[Unit]
Description=redis_exporter
[Service]
ExecStart=/usr/local/bin/redis_exporter -redis.addr redis://$DB_IP:6379 -web.listen-address $DB_IP:9121
Restart=always
Nice=-15
[Install]
WantedBy=multi-user.target
UNIT
mkdir -p /etc/systemd/system/prometheus-node-exporter.service.d; printf '[Service]\nNice=-15\n' > /etc/systemd/system/prometheus-node-exporter.service.d/nice.conf
sysctl -qw vm.overcommit_memory=1   # same for both: background saves fork without warnings
systemctl daemon-reload; systemctl restart prometheus-node-exporter; systemctl enable -q --now kv-exporter
docker images --format '{{.Repository}}:{{.Tag}} {{.Size}}'
