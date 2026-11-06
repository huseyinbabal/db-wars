#!/usr/bin/env bash
# Delete every droplet of this series (tag dbwars4). Take the Grafana screenshots first.
set -euo pipefail
doctl compute droplet list --tag-name dbwars4 --format Name --no-header
doctl compute droplet delete --tag-name dbwars4 --force
