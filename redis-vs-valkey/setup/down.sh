#!/usr/bin/env bash
doctl compute droplet delete --tag-name dbwars5 --force; sleep 5; echo "left: $(doctl compute droplet list --tag-name dbwars5 --no-header | wc -l)"
