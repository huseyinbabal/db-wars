#!/usr/bin/env bash
# While a fixed-rate read round runs: where the database machine spends CPU, syscalls and context switches. Writes results/diag-<mix>/
cd "$(dirname "$0")"; R=run; MIX=$1; RATE=$2
ssh_() { ssh -F $R/ssh_config "$@"; }
for s in pg my; do ssh_ $s-db 'apt-get install -y -qq linux-tools-$(uname -r) linux-tools-common strace >/dev/null 2>&1; which perf' ; done
./round.sh diag-$MIX $MIX $RATE 1 1 70s > /tmp/diag-$MIX.log 2>&1 &
until [ -f results/diag-$MIX/start ] && [ "$(cat results/diag-$MIX/start)" -gt $(( $(date +%s) - 60 )) ]; do sleep 2; done
sleep 25
for s in pg my; do
  P=$([ $s = pg ] && echo postgres || echo mysqld)
  ssh_ $s-db "perf record -F 199 -a -g -o /tmp/p.data -- sleep 15 >/dev/null 2>&1; perf report -i /tmp/p.data --no-children --sort comm,sym --stdio -g none 2>/dev/null | grep -v '^#' | grep -v '^$' | head -28; vmstat 1 5 | tail -5" > results/diag-$MIX/perf-$s.txt 2>&1 &
done
ssh_ my-db "mysql -e \"SHOW GLOBAL STATUS WHERE Variable_name IN ('Questions','Com_stmt_execute','Com_stmt_prepare','Com_stmt_close','Threads_running','Threads_connected','Innodb_row_lock_waits','Innodb_buffer_pool_read_requests','Innodb_buffer_pool_reads','Innodb_os_log_fsyncs','Innodb_data_fsyncs','Innodb_log_writes','Innodb_redo_log_current_lsn')\"" > results/diag-$MIX/my-status-1.txt &
wait %2 %3 %4 2>/dev/null; sleep 1
ssh_ my-db "mysql -e \"SHOW GLOBAL STATUS WHERE Variable_name IN ('Questions','Com_stmt_execute','Com_stmt_prepare','Com_stmt_close','Threads_running','Threads_connected','Innodb_row_lock_waits','Innodb_buffer_pool_read_requests','Innodb_buffer_pool_reads','Innodb_os_log_fsyncs','Innodb_data_fsyncs','Innodb_log_writes','Innodb_redo_log_current_lsn')\"" > results/diag-$MIX/my-status-2.txt
ssh_ pg-db "sudo -u postgres psql -d shop -xc 'select * from pg_stat_wal' -c 'select xact_commit,blks_hit,blks_read from pg_stat_database where datname=\$\$shop\$\$'" > results/diag-$MIX/pg-status-2.txt
wait
