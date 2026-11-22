# PostgreSQL 18 vs 19: same server, same settings

Not an app-vs-database test like the other folders: this one runs the same SQL against two Postgres versions to check claims from the PostgreSQL 19 release notes. Write-up with all tables: [huseyinbabal.dev/posts/postgresql-19-vs-18-benchmark](https://huseyinbabal.dev/posts/postgresql-19-vs-18-benchmark/).

- `postgres:18.7` and `postgres:19.0`, the official Docker images, one at a time on the same droplet
- Same `-c` settings for both: `shared_buffers=2GB`, `maintenance_work_mem=1GB`, `max_wal_size=16GB`, `checkpoint_timeout=30min`, `jit=off`, `log_autovacuum_min_duration=0`
- Autovacuum off through `ALTER SYSTEM` (a `-c autovacuum=off` on the command line would override `ALTER SYSTEM` and block the autovacuum test), switched on only for that test

These results hold for **one DigitalOcean `c-8` droplet (8 dedicated vCPU, 16 GB), Ubuntu 24.04, Docker, one run of the suite**.

## What it tests

| Test | What runs | Runs |
| --- | --- | --- |
| Foreign key bulk load | 5M child rows into a table referencing a 1M-row parent, `INSERT … SELECT` and `COPY`, with and without the FK | 5 |
| Single-row inserts | `pgbench`, 16 clients, 60 s, one `INSERT` per transaction, with and without the FK | 5 |
| NOT IN | `select count(*) from a where x not in (select y from b)`, 5M rows in `a`, 100k or 1M in `b`, both columns `NOT NULL`, 120 s timeout | 5 |
| TOAST | 50k rows of a 200-object `jsonb` document, total size and `pg_column_compression` | 1 |
| Bloat | 5M rows, 80 % deleted, then `VACUUM FULL` (both) and `REPACK`, `REPACK (CONCURRENTLY)` (19) while `pgbench` updates and reads (8 clients, `-P 1`) | 3 |
| Autovacuum | 5M rows, 8 indexes, half deleted, elapsed time from the autovacuum log; 19 with 0 and 4 parallel workers | 3 |

## Run it

```bash
# on any machine with Docker: one version, results in ./out
bash bench.sh 19.0 out
bash bench.sh 18.7 out

# or the way these results were made: one droplet, both versions, results copied back, droplet deleted
DO_TOKEN=... REGION=lon1 ./run-on-digitalocean.sh
```

`bench.sh` takes an optional third argument that divides every table size, for a quick dry run (`bash bench.sh 19.0 out 50`).

## Results

`results/pg<version>.jsonl` has one line per run: `{"version","test","run","value","unit"}`. Medians:

| Test | 18.7 | 19.0 |
| --- | --- | --- |
| COPY 5M rows, FK | 31.45 s | 15.19 s |
| INSERT … SELECT 5M rows, FK | 37.62 s | 21.45 s |
| COPY 5M rows, no FK | 3.67 s | 3.35 s |
| INSERT … SELECT 5M rows, no FK | 9.99 s | 9.69 s |
| pgbench single-row inserts, FK | 30,375 tps | 32,940 tps |
| pgbench single-row inserts, no FK | 35,474 tps | 36,082 tps |
| NOT IN, `b` = 100k | 343 ms | 280 ms |
| NOT IN, `b` = 1M | timeout (120 s) in 5/5 runs | 542 ms |
| TOAST table size | 416,899,072 B (pglz) | 416,899,072 B (lz4) |
| VACUUM FULL | 2.35 s, 1.35 GB → 279 MB | 1.72 s, 1.35 GB → 279 MB |
| REPACK | – | 1.77 s, lowest second 380 tps |
| REPACK (CONCURRENTLY) | – | 2.16 s, 280 MB, lowest second 12,533 tps |
| Autovacuum, 8 indexes | 36.3 s | 35.7 s (0 workers), 33.9 s (4 workers) |

Other files in `results/`:

- `pg<v>.notin_small.plan`, `pg<v>.notin_large.plan`: `EXPLAIN` of the NOT IN query
- `pg<v>.<command>_acct.<run>.pgbench`: per-second pgbench output while each rewrite ran
- `pg<v>.autovac.pw<workers>.<run>.log`: the autovacuum log lines
- `pg<v>.toast`: `pg_column_compression` counts
- `pg<v>.settings`, `pg<v>.version`: non-default settings and `select version()`
- `run.log`: the console output of the whole run
