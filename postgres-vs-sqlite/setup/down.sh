#!/usr/bin/env bash
# Delete every droplet of this episode (tag dbwars3).
set -euo pipefail
doctl compute droplet list --tag-name dbwars3 --format Name --no-header
doctl compute droplet delete --tag-name dbwars3 --force
doctl compute droplet list --tag-name dbwars3 --format Name --no-header | wc -l
