#!/usr/bin/env bash
# Creates one c-8 droplet, runs bench.sh for PG 18.7 and 19.0, copies results back, deletes the droplet.
set -uo pipefail
cd "$(dirname "$0")"
TOK=${DO_TOKEN:?set DO_TOKEN to a DigitalOcean API token}
D="doctl -t $TOK"
NAME=pg19-bench; KEY=$($D compute ssh-key list --format ID --no-header | head -1)
SSH="ssh -i $HOME/.ssh/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"
cleanup(){ echo "deleting droplet"; $D compute droplet delete -f $NAME >/dev/null 2>&1; sleep 5; echo "droplets left: $($D compute droplet list --format Name --no-header | wc -l | tr -d ' ')"; }
fail(){ echo "FAILED: $*"; cleanup; exit 1; }
$D compute droplet create $NAME --size c-8 --region ${REGION:?set REGION, e.g. nyc1} --image ubuntu-24-04-x64 --ssh-keys $KEY --wait >/dev/null || fail "create"
IP=$($D compute droplet get $NAME --format PublicIPv4 --no-header)
for i in $(seq 1 60); do $SSH root@$IP true 2>/dev/null && break; sleep 5; done
$SSH root@$IP true || fail "ssh"
echo "droplet up"
$SSH root@$IP 'cloud-init status --wait >/dev/null; export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq docker.io >/dev/null && docker pull -q postgres:18.7 && docker pull -q postgres:19.0 && nproc && free -g | head -2 && lsblk -d -o NAME,SIZE,ROTA' || fail "setup"
scp -i $HOME/.ssh/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR bench.sh root@$IP:/root/ || fail "scp"
$SSH root@$IP 'nohup bash -c "(bash /root/bench.sh 18.7 /root/out && bash /root/bench.sh 19.0 /root/out) > /root/run.log 2>&1 && touch /root/ok || touch /root/failed" >/dev/null 2>&1 &'
echo "bench started"
last=0
for i in $(seq 1 600); do   # up to 5 h
  sleep 30
  st=$($SSH root@$IP 'test -f /root/ok && echo ok || (test -f /root/failed && echo failed || echo run)' 2>/dev/null || echo sshfail)
  n=$($SSH root@$IP 'cat /root/out/*.jsonl 2>/dev/null | wc -l' 2>/dev/null || echo "?")
  [ "$n" != "$last" ] && { echo "progress: $n results"; $SSH root@$IP 'tail -1 -q /root/out/*.jsonl 2>/dev/null | tail -1'; last=$n; }
  case $st in ok) break;; failed) $SSH root@$IP 'tail -20 /root/run.log'; mkdir -p results; scp -r -i $HOME/.ssh/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@$IP:/root/out/. results/ ; fail "bench";; esac
done
[ "$st" = ok ] || fail "timeout"
mkdir -p results
scp -r -i $HOME/.ssh/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@$IP:/root/out/. root@$IP:/root/run.log results/ || fail "fetch"
echo "results fetched"
cleanup
echo ALLDONE
