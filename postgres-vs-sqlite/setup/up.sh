#!/usr/bin/env bash
# Two identical stacks side by side in one private network, plus one monitor machine:
#   pg-srv / sl-srv   c-2 (2 dedicated vCPU, 4 GiB)   the Go app AND the database on the same machine (SQLite has no server;
#                                                     Postgres is reached over its local Unix socket). Both databases on both machines.
#   pg-load / sl-load s-8vcpu-16gb                    k6 (big enough that the load never limits the server)
#   mon               s-1vcpu-2gb                     Prometheus + Grafana (nothing public)
#   ./up.sh   -> writes ../run/ssh_config and ../run/hosts.env
set -euo pipefail
cd "$(dirname "$0")"; mkdir -p ../run
REGION=${REGION:-lon1}; IMG=ubuntu-24-04-x64; TAG=dbwars3
KEY=$(doctl compute ssh-key list --format ID --no-header | head -1)
create() { doctl compute droplet create "$1" --region $REGION --image $IMG --size "$2" --ssh-keys "$KEY" --tag-name $TAG --enable-private-networking --wait --format Name,PublicIPv4,PrivateIPv4 --no-header; }
for spec in pg-srv:c-2 sl-srv:c-2 pg-load:s-8vcpu-16gb sl-load:s-8vcpu-16gb mon:s-1vcpu-2gb; do
  create "${spec%%:*}" "${spec#*:}" &
done; wait
doctl compute droplet list --tag-name $TAG --format Name,PublicIPv4,PrivateIPv4 --no-header | sort > ../run/droplets.txt
: > ../run/ssh_config; : > ../run/hosts.env
while read -r name pub priv; do
  printf 'Host %s\n  HostName %s\n  User root\n  IdentityFile ~/.ssh/id_rsa\n  IdentitiesOnly yes\n  StrictHostKeyChecking accept-new\n  UserKnownHostsFile %s/../run/known_hosts\n  ServerAliveInterval 30\n\n' "$name" "$pub" "$PWD" >> ../run/ssh_config
  echo "$(echo "$name" | tr a-z- A-Z_)_IP=$priv" >> ../run/hosts.env
done < ../run/droplets.txt
wc -l < ../run/hosts.env
