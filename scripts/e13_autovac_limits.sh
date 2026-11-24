#!/bin/bash
# E13: autovacuum の設定・資源の限界
#  13a テーブル単位 autovacuum_freeze_max_age: 全体値より大きくはできない (小さくはできる)
#  13b ワーカー枯渇: XID もスナップショットも持たない「ロックだけ保持」の放置トランザクションで
#      周回防止ワーカー (既定 3 本) が全員ロック待ちになり、他の DB が誰にも VACUUM されなくなる
#  13c コスト遅延の変更は実行中の周回防止 VACUUM にも reload で効く (PG16+)
source /vagrant/scripts/common.sh
P=5514; N=e13
new_cluster $N $P
q $P postgres "CREATE EXTENSION xid_wraparound"

say "13a: per-table autovacuum_freeze_max_age = 2e9 (higher than global 2e8) vs 1e8 (lower)"
q $P postgres "CREATE TABLE hi(i int) WITH (autovacuum_freeze_max_age = 2000000000); INSERT INTO hi VALUES (1);"
q $P postgres "CREATE TABLE lo(i int) WITH (autovacuum_freeze_max_age = 100000000); INSERT INTO lo VALUES (1);"
q $P postgres "VACUUM (FREEZE)" >/dev/null
echo "csv13a,consumed_M,age_hi,age_lo"
# 10M ごとに 3 秒待つ (autovacuum_naptime=10s の起動待ちが XID 数で大きく見えすぎないように)
for i in $(seq 1 25); do consume $P 10; echo "csv13a,$((i*10)),$(qa $P postgres "SELECT (SELECT age(relfrozenxid) FROM pg_class WHERE relname='hi')||','||(SELECT age(relfrozenxid) FROM pg_class WHERE relname='lo')")"; sleep 3; done | tee /tmp/e13a
# 初めて age が消費量より大きく下がった (= VACUUM された) 時点の消費量 (M)
reset_at(){ awk -F, -v c=$1 '$1=="csv13a" && $2~/^[0-9]+$/ && $c < $2*1000000*0.9 {print $2; exit}' /tmp/e13a; }
LO=$(reset_at 4); HI=$(reset_at 3)
echo "lo (reloption 1e8) first vacuumed at ${LO:-never}M consumed; hi (reloption 2e9) at ${HI:-never}M"
metric lo_first_vacuumed_at_M ${LO:-0}
sleep 12
q $P postgres "SELECT relname, age(relfrozenxid), last_autovacuum FROM pg_stat_user_tables JOIN pg_class USING (relname) WHERE relname IN ('hi','lo')"
check reloption_cannot_raise_freeze_max_age test "$(qa $P postgres "SELECT age(relfrozenxid) < 200000000 FROM pg_class WHERE relname='hi'")" = t
check reloption_can_lower_freeze_max_age test -n "$LO" -a "${LO:-999}" -lt 200
check reloption_2e9_not_vacuumed_before_global_2e8 test "${HI:-999}" -ge 200
q $P postgres "VACUUM (FREEZE)" >/dev/null; vacuumdb -q -p $P --all --freeze

say "13b: an idle transaction that only holds SHARE locks on 3 tables in appdb (no XID, no snapshot)"
q $P postgres "CREATE DATABASE appdb"
q $P appdb "CREATE EXTENSION xid_wraparound"
q $P appdb "CREATE TABLE l1(i int); CREATE TABLE l2(i int); CREATE TABLE l3(i int); INSERT INTO l1 VALUES (1); INSERT INTO l2 VALUES (1); INSERT INTO l3 VALUES (1);"
vacuumdb -q -p $P --all --freeze
( printf "BEGIN;\nLOCK TABLE l1, l2, l3 IN SHARE MODE;\n\\\\! sleep 100000\n" | PGAPPNAME=lock_holder psql -X -p $P -d appdb >/dev/null 2>&1 ) 2>/dev/null &
sleep 2
q $P postgres "SELECT application_name, state, backend_xid, backend_xmin FROM pg_stat_activity WHERE application_name='lock_holder'"
check lock_holder_has_no_xid_no_xmin test "$(qa $P postgres "SELECT count(*) FROM pg_stat_activity WHERE application_name='lock_holder' AND backend_xid IS NULL AND backend_xmin IS NULL")" -eq 1
logmark $N
echo "csv13b,consumed_M,age_appdb,age_postgres,age_template1,age_template0,av_workers,av_waiting_on_lock,msg"
for i in $(seq 1 230); do
  out=$(psql -X -At -p $P -d appdb -c "SELECT consume_xids(10000000)" 2>&1)
  msg=$(echo "$out" | grep -E '^(WARNING|ERROR)' | head -1 | cut -c1-60)
  if [ $((i % 10)) -eq 0 ] || [ -n "$msg" ]; then
    echo "csv13b,$((i*10)),$(qa $P postgres "SELECT string_agg(age(datfrozenxid)::text, ',' ORDER BY array_position(ARRAY['appdb','postgres','template1','template0'], datname::text)) FROM pg_database")","$(qa $P postgres "SELECT count(*)||','||count(*) FILTER (WHERE wait_event_type='Lock') FROM pg_stat_activity WHERE backend_type='autovacuum worker'"),$msg"
    sleep 1
  fi
  echo "$out" | grep -q '^ERROR' && break
done | tee /tmp/e13b
echo "--- autovacuum workers at STOP:"
q $P postgres "SELECT pid, datname, wait_event_type, wait_event, pg_blocking_pids(pid) AS blocked_by, left(query,60) AS query FROM pg_stat_activity WHERE backend_type='autovacuum worker'"
echo "--- diag.sql: no backend_xmin row; only the 'autovacuum_blocked' rows (added after this finding) point to the culprit:"
diag $P appdb | head -12
check diag_shows_autovacuum_blocked test "$(diag $P appdb | grep -c 'autovacuum_blocked')" -ge 3
echo "--- pg_locks does:"
q $P appdb "SELECT l.relation::regclass, l.mode, l.granted, a.application_name, a.backend_type, a.state FROM pg_locks l JOIN pg_stat_activity a USING (pid) WHERE l.locktype='relation' AND l.relation IN ('l1'::regclass,'l2'::regclass,'l3'::regclass) ORDER BY 1, 3 DESC"
state $P
check stop_reached_by_lock_only_blocker test "$(qs $P appdb "SELECT pg_current_xact_id()")" = 54000
check all_workers_waiting_on_lock test "$(qa $P postgres "SELECT count(*) FROM pg_stat_activity WHERE backend_type='autovacuum worker' AND wait_event_type='Lock'")" -eq 3
check other_db_starved_postgres_not_vacuumed test "$(qa $P postgres "SELECT age(datfrozenxid) > 1000000000 FROM pg_database WHERE datname='postgres'")" = t
metric starved_postgres_age_at_stop $(qa $P postgres "SELECT age(datfrozenxid) FROM pg_database WHERE datname='postgres'")
check no_xmin_blocker_visible test "$(qa $P postgres "SELECT count(*) FROM pg_stat_activity WHERE backend_type='client backend' AND pid<>pg_backend_pid() AND (backend_xmin IS NOT NULL OR backend_xid IS NOT NULL)")" -eq 0
say "13b recovery: terminate the lock holder"
qa $P postgres "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name='lock_holder'" >/dev/null
pkill -f 'sleep 100000' 2>/dev/null
can_write(){ test "$(qs $P appdb "SELECT pg_current_xact_id()")" = OK; }
W=$(wait_until 300 can_write); echo "writes resumed after $W s"
metric lock_starvation_recovery_s $W
check recovers_after_lock_holder_gone test "$W" != -1
state $P

say "13c: change cost delay of a RUNNING anti-wraparound autovacuum with reload"
q $P postgres "CREATE TABLE big(id int, pad text) WITH (autovacuum_enabled=false); INSERT INTO big SELECT g, repeat('c',150) FROM generate_series(1,6000000) g;"
q $P postgres "SELECT pg_size_pretty(pg_relation_size('big'))"
q $P postgres "ALTER SYSTEM SET autovacuum_vacuum_cost_delay = '20ms'"; qa $P postgres "SELECT pg_reload_conf()" >/dev/null
consume $P 210
av_on_big(){ [ -n "$(qa $P postgres "SELECT 1 FROM pg_stat_progress_vacuum WHERE relid='big'::regclass")" ]; }
wait_until 180 av_on_big >/dev/null
rate(){ # 20 秒間のヒープ走査速度 (MB/s)
  local a=$(qa $P postgres "SELECT heap_blks_scanned FROM pg_stat_progress_vacuum WHERE relid='big'::regclass")
  local tot=$(qa $P postgres "SELECT pg_relation_size('big')/8192")
  local t0=$(now) b el
  for i in $(seq 1 20); do sleep 1; b=$(qa $P postgres "SELECT heap_blks_scanned FROM pg_stat_progress_vacuum WHERE relid='big'::regclass"); [ -z "$b" ] && { b=$tot; break; }; done
  el=$(since $t0)
  echo "scale=1; ($b - $a) * 8192 / 1048576 / $el" | bc
}
R1=$(rate); echo "cost_delay=20ms (PG11 以前の既定): $R1 MB/s"
q $P postgres "ALTER SYSTEM SET autovacuum_vacuum_cost_delay = 0"; qa $P postgres "SELECT pg_reload_conf()" >/dev/null; sleep 2
R2=$(rate); echo "after reload to cost_delay=0: $R2 MB/s"
metric rate_mbps_delay20 $R1; metric rate_mbps_delay0 $R2
check reload_speeds_up_running_antiwrap test "$(echo "$R2 > $R1 * 3" | bc)" = 1
log_audit $N
finish
