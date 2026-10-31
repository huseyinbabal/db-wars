# Postgres JSONB vs MongoDB: the same orders, side by side

One Go service (`app/`), two databases, one k6 script (`k6/doc.js`). Every order is a JSON document: stored in a `jsonb` column in PostgreSQL and as a document in MongoDB, byte for byte the same.

- PostgreSQL 18 (pgx driver) and MongoDB 8.2.12 (official Go driver), installed from their own repositories, no Docker
- Two identical stacks run at the same moment in one DigitalOcean region, so both see the same time of day and the same network
- Every round starts from freshly loaded data: 1,000,000 orders, three indexes (order id, customer, products inside the order)

## Machines

DigitalOcean `lon1`, Ubuntu 24.04, private networking. `setup/up.sh` creates them with `doctl` (tag `dbwars2`), `setup/down.sh` deletes them.

| Machine | Size | What runs on it |
| --- | --- | --- |
| pg-db, mg-db | `c-2` (2 dedicated vCPU, 4 GB) | PostgreSQL or MongoDB, one running at a time |
| pg-app, mg-app | `s-8vcpu-16gb` | the Go service, big enough that it never limits the database |
| pg-load, mg-load | `s-8vcpu-16gb` | k6 |
| mon | `s-1vcpu-2gb` | Prometheus and Grafana (listen on 127.0.0.1, reached through an ssh tunnel) |

`c-2` is not offered in `ams3`, which is why the test runs in `lon1`.

## Setup

```bash
cd setup
./up.sh          # creates the droplets, writes ../run/ssh_config and ../run/hosts.env
./provision.sh   # builds app/ for Linux, installs both databases, the app, k6, Prometheus and Grafana
```

`provision.sh` makes the database passwords with `openssl rand` in its own shell; they are not written to this repository.

## Equal settings

`setup/db.sh` writes these. Nothing that matters is left on a default.

| | PostgreSQL | MongoDB |
| --- | --- | --- |
| Own cache | `shared_buffers = 1GB` | `wiredTiger.engineConfig.cacheSizeGB: 1` |
| Durability | `fsync = on`, `synchronous_commit = on` | write concern `w=1`, `journal=true` |
| Replication log | `wal_level = minimal`, `max_wal_senders = 0` | standalone `mongod`, no oplog |
| Connections | `max_connections = 200`, app pool 100 | app pool 100 |
| Huge pages | THP `madvise` | THP `always` (MongoDB 8 production notes) |
| TLS | off | off |

## A round

```bash
./round.sh <name> <mix> <items per order> <START> <STEP> <STEPS> <HOLD> [orders]
./round.sh read-1 read 3 1000 1000 12 30s
PG_TUNE="ALTER INDEX orders_items SET (fastupdate = off)" ./round.sh shop-tuned-1 shop 3 400 400 12 30s
SWAP=1 ./round.sh shop-tuned-swap shop 3 400 400 12 30s     # each database on the other stack's machines
```

k6 sends a fixed number of requests per second (arrival rate, not virtual users), and the rate goes up by `STEP` every `HOLD`. A slow database cannot slow the test down. During the round the database machines record `vmstat`, `iostat`, `top` and `pidstat` every second, and Postgres' GIN pending list every 2 s (`pgsample.sh`). `steps2.py` turns each run into one line per step; `aggregate.py` makes `results/summary.json`.

The batches in the order they ran: `batch2.sh`, `batch3.sh`, `batch4.sh`. `diag.sh` is the Postgres-only run that found why the shop mix falls over (wait events, `perf`, `EXPLAIN`).

## Results

A database **holds** a rate while p95 stays under 50 ms and fewer than 1% of requests fail. The number is the highest rate it held; main rounds ran three times and the table shows the median.

| Round | PostgreSQL | MongoDB | Runs |
| --- | --- | --- | --- |
| Reads (by id, customer's latest, orders containing a product) | 4,977 | 8,953 | 3 |
| New orders | 5,964 | 3,955 | 3 |
| Status updates | 4,962 | 3,967 | 3 |
| Shop mix, defaults | fails at the first step (400/s) | 4,980+ | 3 |
| Shop mix, `fastupdate = off` | 5,474 | 4,982 | 3 |
| Shop mix, `fastupdate = off`, hosts swapped | 6,477 | 4,487 | 1 |
| New orders, `fastupdate = off` | 2,970 | 3,966 | 1 |
| Big orders (40 items): status updates | 1,492 | 4,479 | 1 |
| Big orders (40 items): reads | 4,988 | 5,980+ | 1 |

`+` means the database still held the top of the tested range.

## Why the shop mix fails on Postgres

1. pgx prepares every statement. After five executions Postgres compares a generic plan with the custom plans it made so far.
2. The generic plan for `doc->'items' @> $1 LIMIT 10` does not know the product, guesses 10,000 matches and picks a Seq Scan (cost about 98).
3. The GIN index has `fastupdate = on` by default: new entries go to a pending list first, and the planner adds that list to the index plan's cost. With 124 pending pages the custom plan costs about 639.
4. The scan now looks cheaper, so every product search reads about 320,000 orders to find 10. All connections end up on the CPU, none of them wait on locks.

`ALTER INDEX orders_items SET (fastupdate = off)` keeps the index plan at about 61, at the price of index work on every insert (new orders drop from 5,964 to 2,970 per second). Not measured here: `plan_cache_mode = force_custom_plan`, or pgx without prepared statements.

## Scope

One database machine per side, no replicas, no sharding, documents read and written whole. MongoDB led on reads and on big documents that change in place; PostgreSQL led on small inserts and updates, and on the shop mix once the GIN setting was changed.
