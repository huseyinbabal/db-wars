#!/usr/bin/env bash
# Redis vs Valkey machines, one private network, lon1:
#   kv-db   c-4  (4 dedicated vCPU, 8 GiB)   Redis or Valkey in Docker, one at a time
#   kv-app  c-16                             kvshop (big enough that the app never limits the server)
#   kv-load c-16                             k6 (same reason)
#   kv-mon  s-2vcpu-4gb                      Prometheus + Grafana (private address / localhost only)
set -euo pipefail
cd "$(dirname "$0")"; mkdir -p ../run
REGION=lon1; IMG=ubuntu-24-04-x64; TAG=dbwars5
KEY=$(doctl compute ssh-key list --format ID --no-header | head -1)
create() { doctl compute droplet create "$1" --region $REGION --image $IMG --size "$2" --ssh-keys "$KEY" --tag-name $TAG --enable-private-networking --wait --format Name --no-header; }
for spec in kv-db:c-4 kv-app:c-16 kv-load:c-16 kv-mon:s-2vcpu-4gb; do create "${spec%%:*}" "${spec#*:}" & done; wait
doctl compute droplet list --tag-name $TAG --format Name,PublicIPv4,PrivateIPv4 --no-header | sort > ../run/droplets.txt
: > ../run/ssh_config; : > ../run/hosts.env
while read -r name pub priv; do
  printf 'Host %s\n  HostName %s\n  User root\n  IdentityFile ~/.ssh/id_rsa\n  IdentitiesOnly yes\n  StrictHostKeyChecking accept-new\n  UserKnownHostsFile %s/../run/known_hosts\n  ControlMaster no\n\n' "$name" "$pub" "$PWD" >> ../run/ssh_config
  echo "$(echo "$name" | tr a-z- A-Z_)_IP=$priv" >> ../run/hosts.env
done < ../run/droplets.txt
wc -l < ../run/droplets.txt
