# Postgres vs MySQL: same app, same machine

One Go service (`app/`) with the same SQL on both databases, one k6 script (`k6/shop.js`). `DB_KIND` picks the database.

- PostgreSQL 18 (pgx) and MySQL 9.7 LTS (go-sql-driver/mysql), installed from their own package repositories, no Docker
- Two identical stacks run at the same moment in one DigitalOcean region; each database is alone on its machine
- Every round starts from freshly loaded data: 5,000,000 orders, 100,000 products

These results hold for **one database machine with 2 dedicated vCPUs and 4 GB, no replicas, no connection pooler, read committed on both sides**.

## Machines

DigitalOcean `lon1`, Ubuntu 24.04, private networking. `setup/up.sh` creates them with `doctl` (tag `dbwars4`), `setup/down.sh` deletes them.

| Machine | Size | What runs on it |
| --- | --- | --- |
| pg-db, my-db | `c-2` (2 dedicated vCPU, 4 GB) | the database, alone |
| pg-app, my-app | `s-8vcpu-16gb` | the Go service |
| pg-load, my-load | `s-8vcpu-16gb` | k6 |
| mon | `s-1vcpu-2gb` | Prometheus and Grafana, not public |

Both `c-2` machines must report the same CPU model.

## Setup

```bash
cd setup
./up.sh          # creates the droplets, writes ../run/ssh_config and ../run/hosts.env
./provision.sh   # builds the app, installs both databases, k6, Prometheus and Grafana
```

## Equal settings

`setup/db.sh` writes these.

| | PostgreSQL | MySQL |
| --- | --- | --- |
| Own cache | `shared_buffers = 1GB` (the OS page cache holds the rest) | `innodb_buffer_pool_size = 2560M`, `innodb_flush_method = O_DIRECT` |
| Durability | `fsync = on`, `synchronous_commit = on` | `innodb_flush_log_at_trx_commit = 1` |
| Replication log | `wal_level = minimal`, `max_wal_senders = 0` | `skip-log-bin` |
| Isolation | read committed | `READ-COMMITTED` |
| Connections | `max_connections = 200`, app pool 100 | `max_connections = 200`, app pool 100 |

## A round

```bash
./round.sh <name> <mix> <START> <STEP> <STEPS> <HOLD> [orders]
./round.sh read-1 read 2000 1000 14 30s
SWAP=1 ./round.sh read-swap read 2000 1000 14 30s                 # each database on the other stack's machine
./round.sh read-20m read 1000 1000 14 30s 20000000                # 20 million orders
LONG_TX=1700 ./round.sh longtx-status status 2000 1 1 1500s       # one repeatable read transaction held open on each database
```

Mixes (`k6/shop.js`): `read`, `insert` (new orders), `shop5`, `shop20`, `views` (update of a column without an index), `status` (update of an indexed column). k6 sends a fixed number of requests per second, and the rate goes up by `STEP` every `HOLD`. `batch1.sh` and `batch2.sh` are every round, in the order they ran. `aggregate.py` writes `results/summary.json`.

## Results

A database **holds** a rate while p95 stays under 50 ms and fewer than 1% of requests fail. The number is the highest rate it held; rounds that ran three times show the median. `+` means it still held at the last step, so the limit is higher. `results/summary.json` has every run.

| Round | PostgreSQL | MySQL | Runs |
| --- | --- | --- | --- |
| Reads | 13,947+ | 6,966 | 3 |
| New orders | 1,397 | 997 | 3 |
| Shop, 1 write in 20 | 8,985 | 4,969 | 3 |
| Shop, 1 write in 5 | 6,974+ | 3,981 | 3 |
| Updates, column without index | 7,948 | 3,975 | 3 |
| Updates, indexed column | 5,486 | 3,983 | 3 |
| Reads, hosts swapped | 14,868+ | 6,969 | 1 |
| Reads, 20 million orders | 9,968 | 3,978 | 1 |

With one transaction held open for the whole 25 minute update round, Postgres p95 averaged about 325 ms over the last minutes while MySQL stayed near 20 ms.

Video: https://youtu.be/-_5gK8TbLGw
