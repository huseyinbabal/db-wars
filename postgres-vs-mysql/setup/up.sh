#!/usr/bin/env bash
# Two identical stacks side by side in one private network, plus one monitor machine:
#   pg-db / my-db   c-2 (2 dedicated vCPU, 4 GiB)   both databases installed on both, one running
#   pg-app / my-app s-8vcpu-16gb                    shop (big enough that the app never limits the database)
#   pg-load / my-load s-8vcpu-16gb                  k6 (same reason)
#   mon             s-1vcpu-2gb                     Prometheus + Grafana (nothing public)
#   ./up.sh   -> writes ../run/ssh_config and ../run/hosts.env
set -euo pipefail
cd "$(dirname "$0")"; mkdir -p ../run
REGION=${REGION:-lon1}; IMG=ubuntu-24-04-x64; TAG=dbwars4   # lon1: ams3 has no 2-vCPU dedicated (c-2) size
KEY=$(doctl compute ssh-key list --format ID --no-header | head -1)
create() { doctl compute droplet create "$1" --region $REGION --image $IMG --size "$2" --ssh-keys "$KEY" --tag-name $TAG --enable-private-networking --wait --format Name,PublicIPv4,PrivateIPv4 --no-header; }
for spec in ${DB_SPECS-pg-db:c-2 my-db:c-2} pg-app:s-8vcpu-16gb my-app:s-8vcpu-16gb pg-load:s-8vcpu-16gb my-load:s-8vcpu-16gb mon:s-1vcpu-2gb; do
  create "${spec%%:*}" "${spec#*:}" &
done; wait
doctl compute droplet list --tag-name $TAG --format Name,PublicIPv4,PrivateIPv4 --no-header | sort > ../run/droplets.txt
: > ../run/ssh_config; : > ../run/hosts.env
while read -r name pub priv; do
  printf 'Host %s\n  HostName %s\n  User root\n  IdentityFile ~/.ssh/id_rsa\n  IdentitiesOnly yes\n  StrictHostKeyChecking accept-new\n  UserKnownHostsFile %s/../run/known_hosts\n\n' "$name" "$pub" "$PWD" >> ../run/ssh_config
  echo "$(echo "$name" | tr a-z- A-Z_)_IP=$priv" >> ../run/hosts.env
done < ../run/droplets.txt
cat ../run/hosts.env
