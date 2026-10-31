# Database Wars

The same application, a different database, measured with k6. Each folder is one comparison, with the scripts that produced its numbers.

| Folder | Comparison |
| --- | --- |
| [`postgres-vs-mariadb/`](postgres-vs-mariadb/) | PostgreSQL 18 vs MariaDB 12.3: same Go service, same machine, up to 3,200 users |
| [`postgres-vs-mongodb/`](postgres-vs-mongodb/) | PostgreSQL 18 JSONB vs MongoDB 8.2: the same order documents, two identical stacks side by side |
