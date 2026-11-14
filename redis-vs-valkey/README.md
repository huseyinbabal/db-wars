# Redis vs Valkey: same app, same machine

One Go service (`app/`, go-redis v9, pool of 200 connections) and one k6 script (`k6/shop.js`). The app talks to whatever answers on `KV_ADDR`, so the same binary runs against both servers.

- Redis 8.10.3 (`redis:8.10.3-trixie`) and Valkey 9.1.3 (`valkey/valkey:9.1.3-trixie`), the official Docker images with default settings
- One server at a time on the same machine, a fresh container for every run
- Every run starts from 1,000,000 product hashes (8 fields each), loaded by `kvshop seed`

These results hold for **one server machine with 4 dedicated vCPUs and 8 GB, no cluster, no replicas, default persistence (RDB snapshots, no AOF)**. The Redis 8 image also loads its default modules (Search, JSON, Bloom, TimeSeries, vector sets); none of them is used by the test.

## Machines

DigitalOcean `lon1`, Ubuntu 24.04, private networking. `setup/up.sh` creates them with `doctl` (tag `dbwars5`), `setup/down.sh` deletes them.

| Machine | Size | What runs on it |
| --- | --- | --- |
| kv-db | `c-4` (4 dedicated vCPU, 8 GB) | Redis or Valkey in Docker, one at a time, plus redis_exporter |
| kv-app | `c-16` | the Go service, big enough that it never limits the server |
| kv-load | `c-16` | k6 |
| kv-mon | `s-2vcpu-4gb` | Prometheus and Grafana, private address only |

```bash
cd setup
./up.sh          # creates the droplets, writes ../run/ssh_config and ../run/hosts.env
./provision.sh   # installs Docker + both images, the app, k6, Prometheus and Grafana
```

## The workload

Each k6 iteration is one user request. The app turns it into two or three round trips:

| Share | Request | Commands |
| --- | --- | --- |
| 60% | `GET /products/{id}` | `HGETALL product:{id}`, `INCR views:{id}`, `ZINCRBY trending 1 {id}` |
| 20% | `GET /trending` | `ZREVRANGE trending 0 9 WITHSCORES`, then a pipeline of 10 `HMGET` |
| 20% | `POST /cart/{user}` | `HINCRBY cart:{user} {product} 1`, `EXPIRE cart:{user} 1800` |

k6 uses a `ramping-arrival-rate` executor: it starts at 10,000 requests per second and adds 5,000 every 35 seconds (5 s ramp, 30 s hold) up to 45,000. Each step is measured over its last 25 seconds.

## A run

```bash
./run1.sh <redis|valkey> <io-threads> <name> [START STEP STEPS HOLD]
./run1.sh redis 1 io1-r1 10000 5000 8 30s
./batch.sh       # both rounds, three runs each, order R V V R R V so neither server always goes first
python3 analyze.py   # per-step numbers from Prometheus and the run files -> results/summary.json
```

`run1.sh` starts a fresh container (`--io-threads N`, nothing else changed), seeds 1M products, waits 20 s, records `pidstat -t`, `vmstat` and `top -H` on the server while k6 runs, then saves `INFO all`, the app's pool stats and the k6 summary.

## Results

The number is the highest request rate the server reached while k6 kept raising it (k6 asked for up to 45,000). Every round ran three times; the table shows the median. No request failed in any of the 12 runs. `results/summary.json` has every step of every run.

| Round | Redis 8.10.3 | Valkey 9.1.3 | Runs |
| --- | --- | --- | --- |
| Default settings (`io-threads 1`) | 34,863 | 32,227 | 3 |
| `io-threads 3` | 39,306 | 36,079 | 3 |

Each run, in req/s:

| Round | Redis | Valkey |
| --- | --- | --- |
| `io-threads 1` | 31,916 / 36,399 / 34,863 | 33,186 / 32,227 / 30,333 |
| `io-threads 3` | 39,713 / 38,988 / 39,306 | 36,614 / 32,692 / 36,079 |

- With `io-threads 1` both main threads sat at 93–97% CPU at the peak; the other three cores were mostly idle.
- With `io-threads 3` Valkey's first I/O thread was at 99.6–99.9% and its main thread at 91–96%. Redis's main thread was at 67–77% and its I/O threads at 69–80%, so Redis was not the limit in that round. A Redis rerun with a pool of 600 connections peaked at about the same rate.
- Memory after loading the same 1M products (`INFO memory`, `used_memory`): Redis 236.0–236.1 MiB, Valkey 238.7–239.3 MiB.

## Pull requests

`ci/bench.conf` and `ci/compose.yml` run a short version of the same test on a GitHub runner: 100,000 products, 1,000 to 6,000 req/s, both servers with `io-threads 1`. See the main README for how the comparison works.
