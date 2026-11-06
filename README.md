# Database Wars

The same application, a different database, measured with k6. Each folder is one comparison, with the scripts that produced its numbers.

| Folder | Comparison |
| --- | --- |
| [`postgres-vs-mariadb/`](postgres-vs-mariadb/) | PostgreSQL 18 vs MariaDB 12.3: same Go service, same machine, up to 3,200 users |
| [`postgres-vs-mysql/`](postgres-vs-mysql/) | PostgreSQL 18 vs MySQL 9.7 LTS: the same shop on identical 2 vCPU machines, reads, writes, updates and one open transaction |
| [`postgres-vs-mongodb/`](postgres-vs-mongodb/) | PostgreSQL 18 JSONB vs MongoDB 8.2: the same order documents, two identical stacks side by side |
| [`postgres-vs-sqlite/`](postgres-vs-sqlite/) | PostgreSQL 18 vs SQLite: the same shop on one machine, reads and writes pushed past their limits |

## Pull requests

A pull request that changes a comparison folder gets a short load test: the Go app, k6 and each database on one GitHub runner, running base, PR, PR, base. The results come back as a table in a PR comment, so you can see whether your change moved the numbers. Each folder sets up its run in `ci/bench.conf` and `ci/compose.yml`.

You can change the app and `ci/compose.yml`, which holds the database versions and settings. `setup/` is only used on the real machines, so it has no effect here.

Two things get a PR no numbers, only a note saying why:

- changing the test: `.github/`, `k6/`, `ci/bench.conf` or `results/`
- durability settings in `ci/compose.yml` that let a write return before it reaches the disk, such as `fsync=off`, or data in memory (`tmpfs`)

The arrows compare base with PR on the same runner: 🟢 is better, 🔴 is worse, ⚪ is no clear change (the runs overlap, or the change is under 5% for req/s or 25% for p95). The numbers are for that comparison only. They come from one busy runner, and the results in each folder's README and `results/published.json` come from dedicated machines.
