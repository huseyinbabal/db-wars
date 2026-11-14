#!/usr/bin/env bash
# Two rounds x 3 reps, order alternates so neither server always goes first.
set -uo pipefail
cd "$(dirname "$0")"
for iot in 1 3; do
  rep=0
  for kind in redis valkey valkey redis redis valkey; do
    rep=$((rep+1)); r=$(( (rep+1)/2 ))
    echo "== io$iot $kind rep$r $(date -u +%T)"
    bash run1.sh $kind $iot io$iot-r$r 10000 5000 8 30s 2>&1 | tail -1
  done
done
echo BATCH DONE
