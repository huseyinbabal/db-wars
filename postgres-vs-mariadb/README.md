# Postgres vs MariaDB: same app, same machine

One small Go service, two databases, one load script. The database is the only thing that changes between two runs.

- PostgreSQL 18 and MariaDB 12.3, installed from their own package repositories, no Docker
- Three machines in one private network: load (k6 + Prometheus + Grafana), app (the Go service), db (the database, alone)
- Only one database runs at a time, and each run starts from freshly loaded data

## Machines

DigitalOcean, CPU-optimized (dedicated vCPUs), Ubuntu 24.04, region `lon1`, one VPC.

| Machine | Size | What runs on it |
| --- | --- | --- |
| load | `c-8` (8 vCPU, 16 GB) | k6, Prometheus, Grafana |
| app | `c-4` (4 vCPU, 8 GB) | the Go service (`app/`) |
| db | `c-2` (2 vCPU, 4 GB) | PostgreSQL or MariaDB |

The first trial ran on a shared-CPU droplet. CPU steal went from about 6% to about 50% during the session, so those numbers were thrown away and the test moved to dedicated vCPUs.

Created by hand with `doctl`, one command per machine:

```bash
doctl compute droplet create dbwars-db --region lon1 --size c-2 --image ubuntu-24-04-x64 \
  --ssh-keys <key id> --vpc-uuid <vpc id> --tag-name dbwars --wait
```

k6 reaches the app, and the app reaches the database, only over the private addresses. Prometheus and Grafana listen on `127.0.0.1`.

## Setup

The scripts expect an ssh config with three hosts named `load`, `app` and `db`, and two passwords generated for the run (for example `openssl rand -hex 12`).

```bash
# database machine: both databases installed, settings written, both stopped
ssh -F ssh.conf db  "DB_IP=<db private ip> APP_IP=<app private ip> PG_PW=... MY_PW=... bash -s" < setup/db.sh

# app machine: build the service for Linux, copy it, write one env file per database
(cd app && GOOS=linux GOARCH=amd64 go build -o ../shop-linux .)
scp -F ssh.conf shop-linux app:/usr/local/bin/shop
ssh -F ssh.conf app "DB_IP=... APP_IP=... PG_PW=... MY_PW=... bash -s" < setup/app.sh

# load machine: k6, Prometheus (scrapes all three machines and both database exporters), Grafana
ssh -F ssh.conf load "DB_IP=... APP_IP=... bash -s" < setup/load.sh
```

## Equal settings

Nothing is left on a default. `setup/db.sh` writes these:

| | PostgreSQL | MariaDB |
| --- | --- | --- |
| Connections | `max_connections = 200` | `max_connections = 200` |
| Isolation | `read committed` | `READ-COMMITTED` |
| Durability | `fsync = on`, `synchronous_commit = on` | `innodb_flush_log_at_trx_commit = 1` |
| Replication log | `wal_level = minimal`, `max_wal_senders = 0` | `skip-log-bin` |
| TLS | `ssl = off` | not configured |
| Log size | `max_wal_size = 2GB` | `innodb_log_file_size = 2G` |
| Memory | `shared_buffers = 1GB` | `innodb_buffer_pool_size = 2560M` |

Memory is the one place where they differ on purpose. Postgres uses the operating system page cache behind its own buffers. InnoDB reads with `O_DIRECT` and has no cache behind it, so it gets the larger share.

## The app

`app/` is a small order service: `database/sql` with hand-written SQL, pgx for Postgres and go-sql-driver for MariaDB. The SQL is the same for both; only the placeholder style and the auto-increment spelling differ.

| Endpoint | What it does |
| --- | --- |
| `GET /products/{id}` | one row by primary key |
| `GET /products?category=&after=` | a page of products from an index |
| `GET /orders/{id}` | an order and its items |
| `POST /orders` | one transaction, 7 statements: 2 stock updates, 2 price reads, 1 order insert, 2 item inserts |

Prepared statements are reused on both drivers. Without that, go-sql-driver prepares, executes and closes every query (three round trips) while pgx caches statements, and MariaDB looks about two times slower for a reason that has nothing to do with the database.

The pool is 100 connections (`DB_MAX_OPEN=100`). `shop seed -products 100000 -orders 5000000` loads the data.

## The load

`k6/users.js`: users arrive in levels. Each user sends a request, sleeps 50 to 150 ms, and sends the next one. A level is 10 seconds for the new users to arrive and 80 seconds of hold.

```bash
k6 run -o experimental-prometheus-rw -e BASE_URL=http://<app private ip>:8000 \
  -e WRITES=0.05 -e USERS=100,200,400,800,1600,3200 -e HOLD=80 users.js
```

The first read round and the first write round held each level for 170 seconds and stopped at 1,600 users (`./batch-users.sh read 0.05 100,200,400,800,1600 170`, the same with `write 0.5`); the second and third rounds use the command above.

`WRITES` is the share of requests that create an order. The reads are 50% product by id, 30% product list, 20% order by id.

## Running it

```bash
export SSH_CONF=ssh.conf APP=http://<app private ip>:8000
./batch-limits.sh     # reads x2, writes x2, 20M orders, spike
./batch-spike.sh      # the spike three more times
```

| Script | What it does |
| --- | --- |
| `batch-users.sh` | one round on both databases: stop both, drop the page cache, start one, reload the data, wait 30 s, run |
| `run-users.sh` | one run: starts `vmstat`, `iostat`, `top`, `pidstat` and a load-average loop on db and app, runs k6 on load, copies everything to `results/<name>/` |
| `series.py` | pulls the time series of the run from Prometheus as JSON (5-second step) |
| `stages.py` | prints one line per user level: req/s, p50, p95, p99, failed %, database CPU, load, memory, connections |

`batch-limits.sh` also has a round without a connection pool. That round gave one result I could not explain, so it is not part of the results below.

## Results

Equal settings, pool of 100, 5 million orders unless noted. No request failed in any run.

| Test | Runs | PostgreSQL | MariaDB | Difference |
| --- | --- | --- | --- | --- |
| Reads (95% reads), up to 800 users | 3 | 7,805 / 7,910 / 7,912 req/s, p95 3 to 5 ms | 7,789 / 7,902 / 7,906 req/s, p95 3 to 6 ms | about the same |
| Reads, ceiling | 3 | 12,527 / 13,324 / 13,435 req/s | 10,344 / 10,772 / 11,016 req/s | Postgres +21% to +24% |
| Reads, p95 at 1,600 users | 3 | 55 to 85 ms | 117 to 147 ms | |
| Writes (50% writes), ceiling | 3 | 4,122 / 4,385 / 4,277 req/s | 3,991 / 4,085 / 4,154 req/s | Postgres +3% to +7% |
| 20 million orders, ceiling | 1 | 9,827 req/s | 10,346 req/s | MariaDB +5% |
| Spike 100 → 3,000 → 100 users | 4 | 6,630 / 6,837 / 6,693 / 6,805 req/s | 7,042 / 6,565 / 6,662 / 6,626 req/s | within 6%, both directions |

What the numbers say and what they do not:

- Up to 800 users the two are almost the same (within 0.2% in req/s). The database was not the limit there.
- With mostly reads, Postgres reaches a higher ceiling. At 800 users, doing the same work, the database machine had 35% of its CPU free with Postgres and 23% with MariaDB. I measured that; I did not measure why.
- The 20-million-order round is a single run. The first spike run had MariaDB 6% ahead and the next three had Postgres ahead by up to 4%, so a single run is not enough to call a winner at that distance.
- This is one app, one machine size and one pool size.

## Grafana

`grafana/` has the dashboards used for the video and a note on how the panels were drawn after the machines were deleted.
