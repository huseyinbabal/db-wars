# Postgres vs SQLite: one shop, one machine

One Go service (`app/`) with the same SQL on both databases, one k6 script (`k6/shop.js`). `DB_KIND` picks the database.

- PostgreSQL 18 (pgx driver, local Unix socket) and SQLite 3.53.4 (go-sqlite3, compiled into the app)
- The app runs on the same machine as the database in both cases
- Two identical stacks run at the same moment in one DigitalOcean region
- Every round starts from freshly loaded data: 1,000,000 orders, 100,000 products

These results hold for **one app instance with the database on the same machine**. Two instances with SQLite means two files, and an order created on one instance returns 404 on the other.

## Machines

DigitalOcean `lon1`, Ubuntu 24.04, private networking. `setup/up.sh` creates them with `doctl` (tag `dbwars3`), `setup/down.sh` deletes them.

| Machine | Size | What runs on it |
| --- | --- | --- |
| pg-srv, sl-srv | `c-2` (2 dedicated vCPU, 4 GB) | the app and the database |
| pg-load, sl-load | `s-8vcpu-16gb` | k6 |
| mon | `s-1vcpu-2gb` | Prometheus and Grafana, not public |

Rounds on machines with different CPU models were thrown away and repeated. Both `c-2` machines must report the same model.

## Setup

```bash
cd setup
./up.sh          # creates the droplets, writes ../run/ssh_config and ../run/hosts.env
./provision.sh   # builds the app on pg-srv, installs both databases, k6, Prometheus and Grafana
```

## Equal settings

`setup/srv.sh` writes these.

| | PostgreSQL | SQLite |
| --- | --- | --- |
| Own cache | `shared_buffers = 1GB` | `_cache_size=-10240`: 10 MiB per connection, up to 1 GiB across 100 connections |
| Durability | `fsync = on`, `synchronous_commit = on` | `_journal_mode=WAL`, `_synchronous=FULL` |
| Replication log | `wal_level = minimal`, `max_wal_senders = 0` | none |
| Connections | app pool 100 | app pool 100 |
| Lock wait | | `_busy_timeout=5000` |

## A round

```bash
./round.sh <name> <WRITES share> <START> <STEP> <STEPS> <HOLD>
./round.sh read-1 0 1000 1000 20 30s
LITE_WRITERS=1 ./round.sh shop20-1w-1 0.2 250 250 24 30s   # SQLite writes through a pool of exactly one connection
SWAP=1 ./round.sh read-swap 0 1000 1000 20 30s             # each database on the other stack's machine
PG_POOL=10 ./round.sh write-pgpool10 1 100 100 25 30s      # Postgres pool of 10 connections
```

k6 sends a fixed number of requests per second (arrival rate), and the rate goes up by `STEP` every `HOLD`. `batch.sh` is every round, in the order they ran.

## Results

A database **holds** a rate while p95 stays under 50 ms and fewer than 1% of requests fail. The number is the highest rate it held; rounds that ran three times show the median. `results/summary.json` has every run.

| Round | PostgreSQL | SQLite | Runs |
| --- | --- | --- | --- |
| Reads | 5,963 | 11,934 | 3 |
| New orders | 998 | 398 | 3 |
| Shop, 1 write in 20 | 4,481 | 5,987 | 3 |
| Shop, 1 write in 5 | 2,993 | 1,748 | 3 |
| New orders, SQLite single writer connection | 799 | 499 | 3 |
| Shop, 1 write in 5, SQLite single writer connection | 2,741 | 2,496 | 3 |
| Reads, hosts swapped | 4,959 | 10,963 | 1 |
| Shop, 1 write in 5, single writer, hosts swapped | 2,994 | 1,999 | 1 |
| New orders, Postgres pool of 10 | 696 | 299 | 1 |

Video: https://youtu.be/ulycfdlJaNk
