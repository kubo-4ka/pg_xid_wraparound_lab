#!/bin/bash
# E5: その他の「凍結を止める」運用上の落とし穴
#  5a pg_dump が出力先詰まりで停滞 (スナップショット保持)
#  5b 放置された PREPARE TRANSACTION (再起動しても消えない)
#  5c 長寿命セッションの一時テーブル (autovacuum は他セッションの一時表を処理できない)
#  5d idle in transaction (REPEATABLE READ の SELECT だけ; XID 未割当でも xmin を保持)
#  5e 対策: transaction_timeout / idle_in_transaction_session_timeout
source /vagrant/scripts/common.sh
P=5505; N=e5
new_cluster $N $P
q $P postgres "CREATE EXTENSION xid_wraparound"
q $P postgres "CREATE TABLE t(id int primary key, pad text); INSERT INTO t SELECT g, repeat('x',200) FROM generate_series(1,1000000) g;"
q $P postgres "VACUUM (FREEZE) t" >/dev/null

consume(){ # <M> : consume M million XIDs in 10M chunks, print age every 100M
  echo "csv,case,consumed_M,max_age"
  for i in $(seq 1 $(( $1 / 10 ))); do
    qa $P postgres "SELECT consume_xids(10000000)" >/dev/null
    [ $((i % 10)) -eq 0 ] && echo "csv,$CASE,$((i*10)),$(qa $P postgres "SELECT max(age(datfrozenxid)) FROM pg_database")"
  done
}
blockers(){
  echo "--- pg_stat_activity (xid/xmin holders)"
  q $P postgres "SELECT pid, application_name, state, backend_xid, backend_xmin, age(backend_xmin) AS xmin_age, left(query,40) AS query FROM pg_stat_activity WHERE (backend_xid IS NOT NULL OR backend_xmin IS NOT NULL) AND pid<>pg_backend_pid() ORDER BY xmin_age DESC NULLS LAST"
  echo "--- pg_prepared_xacts"
  q $P postgres "SELECT gid, owner, database, prepared, age(transaction) FROM pg_prepared_xacts"
  echo "--- oldest relations (incl. temp)"
  q $P postgres "SELECT n.nspname, c.relname, c.relpersistence, age(c.relfrozenxid) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.relkind IN ('r','t','m') ORDER BY 4 DESC LIMIT 3"
}
recover_wait(){ # wait for autovacuum to bring age below 250M
  T=$(date +%s)
  for i in $(seq 1 60); do a=$(qa $P postgres "SELECT max(age(datfrozenxid)) FROM pg_database"); [ "$a" -lt 250000000 ] && break; sleep 2; done
  echo "after removing blocker: max age=$a (in $(( $(date +%s) - T )) s by autovacuum)"
  RECOVERED_AGE=$a
}

say "5a: pg_dump stalled by a blocked output pipe (e.g. slow/full backup destination)"
( pg_dump -p $P -d postgres -t t | sleep 100000 ) 2>/dev/null &
DUMP=$!
sleep 3
CASE=pg_dump; consume 400
check pg_dump_holds_back_freeze test "$(maxage $P)" -gt 350000000
blockers
logmark $N; sleep 12; logsince $N | grep -m1 -A1 'far in the past'
pkill -f 'sleep 100000'; wait $DUMP 2>/dev/null; sleep 1
recover_wait
check recovered_after_case1 test "$RECOVERED_AGE" -lt 250000000

say "5b: orphaned prepared transaction (2PC coordinator crashed)"
q $P postgres "BEGIN; INSERT INTO t VALUES (0,'2pc'); PREPARE TRANSACTION 'orphan_gid_1';"
CASE=prepared; consume 300
check prepared_xact_holds_back_freeze test "$(maxage $P)" -gt 250000000
check prepared_xact_invisible_in_pg_stat_activity test "$(qa $P postgres "SELECT count(*) FROM pg_stat_activity WHERE backend_xid IS NOT NULL OR (backend_xmin IS NOT NULL AND pid<>pg_backend_pid())")" -eq 0
blockers
echo "--- restart the server: does it go away?"
stop $N; start $N
q $P postgres "SELECT gid, age(transaction) FROM pg_prepared_xacts"
check prepared_xact_survives_restart test "$(qa $P postgres "SELECT count(*) FROM pg_prepared_xacts")" -eq 1
q $P postgres "SELECT locktype, relation::regclass, mode FROM pg_locks WHERE virtualtransaction LIKE '-1/%'"
q $P postgres "ROLLBACK PREPARED 'orphan_gid_1'"
recover_wait
check recovered_after_case2 test "$RECOVERED_AGE" -lt 250000000

say "5c: long-lived session holding a temp table (idle, NOT in a transaction)"
( printf "CREATE TEMP TABLE work_tmp AS SELECT g FROM generate_series(1,1000) g;\n\\\\! sleep 100000\n" | PGAPPNAME=app_with_temp psql -X -p $P -d postgres >/dev/null 2>&1 ) 2>/dev/null &
TMPS=$!
sleep 2
q $P postgres "SELECT pid, state, backend_xid, backend_xmin FROM pg_stat_activity WHERE application_name='app_with_temp'"
CASE=temp_table; consume 300
check temp_table_session_has_no_xmin test "$(qa $P postgres "SELECT count(*) FROM pg_stat_activity WHERE application_name='app_with_temp' AND backend_xmin IS NULL AND backend_xid IS NULL")" -eq 1
blockers
logmark $N; sleep 12
echo "--- autovacuum log mentioning temp table?"; logsince $N | grep -iE 'temp|work_tmp' | head -3
echo "--- 12s later (autovacuum had time):"
q $P postgres "SELECT n.nspname, c.relname, c.relpersistence, age(c.relfrozenxid) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.relkind IN ('r','t') ORDER BY 4 DESC LIMIT 3"
q $P postgres "SELECT datname, age(datfrozenxid) FROM pg_database"
TN=$(qa $P postgres "SELECT n.nspname||'.'||c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE relname='work_tmp'")
echo "--- other session tries VACUUM $TN"; q $P postgres "VACUUM (VERBOSE) $TN" 2>&1 | head -2
q $P postgres "SELECT relname, age(relfrozenxid) FROM pg_class WHERE relname='work_tmp'"
check other_session_vacuum_of_temp_is_noop test "$(qa $P postgres "SELECT age(relfrozenxid) > 250000000 FROM pg_class WHERE relname='work_tmp'")" = t
check temp_table_holds_back_datfrozenxid test "$(maxage $P)" -gt 250000000
q $P postgres "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name='app_with_temp'" >/dev/null
pkill -f "sleep 100000"
wait $TMPS 2>/dev/null
recover_wait
check recovered_after_case3 test "$RECOVERED_AGE" -lt 250000000

say "5d: idle in transaction with only a snapshot (no XID assigned)"
( printf "BEGIN ISOLATION LEVEL REPEATABLE READ;\nSELECT count(*) FROM t;\n\\! sleep 100000\n" | PGAPPNAME=idle_rr psql -X -p $P -d postgres >/dev/null 2>&1 ) 2>/dev/null &
IRR=$!
sleep 3
CASE=idle_in_xact_snapshot; consume 300
check idle_rr_holds_xmin_without_xid test "$(qa $P postgres "SELECT count(*) FROM pg_stat_activity WHERE application_name='idle_rr' AND backend_xid IS NULL AND backend_xmin IS NOT NULL")" -eq 1
check idle_rr_holds_back_freeze test "$(maxage $P)" -gt 250000000
blockers
q $P postgres "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name='idle_rr'" >/dev/null
pkill -f 'sleep 100000'; wait $IRR 2>/dev/null
recover_wait
check recovered_after_case4 test "$RECOVERED_AGE" -lt 250000000

say "5e: countermeasures (PG17+ transaction_timeout, idle_in_transaction_session_timeout)"
q $P postgres "ALTER ROLE postgres SET idle_in_transaction_session_timeout = '3s'"
q $P postgres "ALTER DATABASE postgres SET transaction_timeout = '5s'"
printf "BEGIN;\nSELECT pg_current_xact_id() IS NOT NULL AS got_xid;\n\\! sleep 5\nSELECT 'still alive?';\n" | psql -X -p $P -d postgres 2>&1
printf "BEGIN;\nSELECT pg_sleep(8);\n" | psql -X -p $P -d postgres 2>&1
logsince $N | grep -E 'terminating connection due to .*timeout' | tee /tmp/e5e.log
check idle_in_transaction_timeout_fires test "$(grep -c 'idle-in-transaction timeout' /tmp/e5e.log)" -ge 1
check transaction_timeout_fires test "$(grep -c 'due to transaction timeout' /tmp/e5e.log)" -ge 1
log_audit $N 'idle-in-transaction timeout|transaction timeout|connection to client lost'
finish
