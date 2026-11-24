#!/bin/bash
# E2: ロングトランザクション1本で凍結を阻害 -> 警告/フェイルセーフ/停止 -> 復旧
#  2a autovacuum=on : 停止中に何ができるか / vacuumdb --all で template0 が残る / 誰が template0 を救うか
#  2b autovacuum=off: 同じ状況で template0 を救うのは誰か (QA F-06)
#  2c autovacuum ワーカーに頼れない場合の最終手段: シングルユーザーモードで template0 を VACUUM
source /vagrant/scripts/common.sh
P=5502; N=e2
new_cluster $N $P
q $P postgres "CREATE EXTENSION xid_wraparound"
q $P postgres "CREATE TABLE t(id int primary key, pad text); INSERT INTO t SELECT g, repeat('x',100) FROM generate_series(1,2000000) g;"
q $P postgres "CREATE TABLE u(id int primary key, v int); INSERT INTO u SELECT g,0 FROM generate_series(1,100000) g; CREATE SEQUENCE s;"

blocker(){
  PGAPPNAME=forgotten_batch psql -X -p $P -d postgres -c "BEGIN; SELECT pg_current_xact_id(); SELECT pg_sleep(86400);" > /tmp/e2_blocker.out 2>&1 &
  sleep 2
}
kill_blocker(){ qa $P postgres "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name='forgotten_batch'" >/dev/null; sleep 1; }
# XID を割り当てられるか (副作用なし。INSERT だと 2 回目以降が一意制約違反になる)
can_write(){ test "$(qs $P postgres "SELECT pg_current_xact_id()")" = OK; }

say "2a: start blocker: BEGIN; pg_current_xact_id(); pg_sleep(...) (application_name=forgotten_batch)"
blocker
q $P postgres "SELECT pid, application_name, backend_xid, backend_xmin, state FROM pg_stat_activity WHERE application_name='forgotten_batch'"
logmark $N

say "consume until ERROR (10M chunk; every chunk sampled)"
T0=$(now)
echo "csv,consumed_M,max_age,first_msg"
for i in $(seq 1 300); do
  out=$(psql -X -At -p $P -d postgres -c "SELECT consume_xids(10000000)" 2>&1)
  msg=$(echo "$out" | grep -E '^(WARNING|ERROR)' | head -1)
  age=$(maxage $P)
  if [ $((i % 10)) -eq 0 ] || [ -n "$msg" ]; then echo "csv,$((i*10)),$age,$msg"; fi
  if echo "$out" | grep -q '^ERROR'; then echo "$out" | grep -E 'ERROR|HINT|WARNING' | tail -4; break; fi
done | tee /tmp/e2.out
EL=$(since $T0)
echo "elapsed to STOP: $EL s"
metric stop_elapsed_s $EL
FIRSTW=$(grep -m1 -oE 'must be vacuumed within [0-9]+' /tmp/e2.out | awk '{print $NF}')
LASTW=$(grep -oE 'must be vacuumed within [0-9]+' /tmp/e2.out | tail -1 | awk '{print $NF}')
metric first_warn_remaining $FIRSTW
metric last_warn_remaining $LASTW
STOPAGE=$(maxage $P)
metric stop_age $STOPAGE
state $P
NX=$(qa $P postgres "SELECT (pg_current_snapshot()::text)")
echo "snapshot at STOP: $NX"
# 停止限界の理論値: wrap limit = oldest datfrozenxid + 2^31-1, stop = wrap - 3,000,000
metric stop_limit_age_theory $(( 2147483647 - 3000000 ))

say "what still works at the STOP state? (expected: reads OK, XID-assigning ops SQLSTATE 54000)"
for s in "SELECT count(*) FROM t" "CHECKPOINT"; do
  r=$(qs $P postgres "$s"); echo "$r  <- $s"; check "stop_allows: $s" test "$r" = OK
done
for s in "SELECT pg_current_xact_id()" \
         "INSERT INTO u VALUES (0,0)" \
         "UPDATE u SET v=1 WHERE id=1" \
         "DELETE FROM u WHERE id=2" \
         "CREATE TABLE newt(i int)" \
         "CREATE TEMP TABLE tmp(i int)" \
         "DROP TABLE u" \
         "TRUNCATE u" \
         "SELECT nextval('s')" \
         "ANALYZE t"; do
  r=$(qs $P postgres "$s"); echo "$r  <- $s"; check "stop_rejects: $s" test "$r" = 54000
done
q $P postgres "INSERT INTO u VALUES (0,0)" | head -2
DUMPROWS=$(pg_dump -p $P -d postgres -t t 2>&1 | grep -cE '^[0-9]+\s')
echo "pg_dump -t t rows: $DUMPROWS"; check stop_allows_pg_dump test "$DUMPROWS" -eq 2000000
check stop_allows_new_connection test "$(qs $P template1 "SELECT 1")" = OK

say "diagnosis (scripts/diag.sql): the blocker is visible via backend_xmin"
diag $P
check diag_shows_blocker test "$(qa $P postgres "SELECT count(*) FROM pg_stat_activity WHERE application_name='forgotten_batch' AND age(backend_xid) > 2000000000")" -eq 1

say "VACUUM while blocker alive (does it help?)"
q $P postgres "VACUUM (VERBOSE) u" 2>&1 | grep -E 'WARNING|HINT|removable cutoff|new relfrozenxid|DETAIL' | head
check vacuum_with_blocker_still_stopped test "$(qs $P postgres "INSERT INTO u VALUES (0,0)")" = 54000

say "server log excerpts during consumption (failsafe / autovacuum warnings)"
L=$LAB/$N/server.log
grep -m1 -B1 -A2 'failsafe' $L
grep -m1 -A1 'is far in the past' $L
grep -m1 -A1 'must be vacuumed within' $L
FS=$(grep -c 'as a failsafe' $L)
echo "failsafe WARNING lines: $FS (distinct tables: $(grep -oE 'maintenance of table "[^"]+"' $L | sort -u | wc -l))"
metric failsafe_msgs $FS
metric failsafe_tables $(grep -oE 'maintenance of table "[^"]+"' $L | sort -u | wc -l)
metric far_in_past_msgs $(grep -c 'is far in the past' $L)
# failsafe が最初に出た時点の age (ログ時刻と csv の対応は取れないので、autovacuum の removable cutoff から算出)
grep -m1 -A6 'as a failsafe' $L | head -3

say "2a RECOVERY: terminate blocker then vacuumdb --all --freeze (multi-user mode, PG14+)"
kill_blocker
T1=$(now)
vacuumdb -p $P --all --freeze -j 3 2>&1 | grep -vE 'bypassing|relfrozenxid or|^HINT|^You might' | sort | uniq -c | tee /tmp/e2.vdb
metric vacuumdb_all_s $(since $T1)
check vacuumdb_all_skips_template0 test "$(grep -c 'vacuuming database "template0"' /tmp/e2.vdb)" -eq 0
state $P
R=$(qs $P postgres "INSERT INTO u VALUES (0,0)"); echo "INSERT right after vacuumdb: $R"
q $P postgres "INSERT INTO u VALUES (0,0)" | head -1
echo "template0 still old right after vacuumdb: $(qa $P postgres "SELECT age(datfrozenxid) > 2000000000 FROM pg_database WHERE datname='template0'") (autovacuum may already be on it)"
say "manual rescue of template0?"
check alter_database_template0_fails_54000 test "$(qs $P postgres "ALTER DATABASE template0 WITH ALLOW_CONNECTIONS true")" = 54000
check connect_template0_refused test "$(qs $P template0 "SELECT 1")" != OK
q $P template0 "SELECT 1" | head -1
say "wait for autovacuum to rescue template0"
W=$(wait_until 120 lt "qa $P postgres \"SELECT age(datfrozenxid) FROM pg_database WHERE datname='template0'\"" 2000000000)
echo "template0 rescued after $W s"; metric template0_rescue_s_av_on $W
check template0_rescued_by_autovacuum test "$W" != -1
grep -m2 'automatic aggressive vacuum to prevent wraparound of table "template0' $L
W=$(wait_until 30 can_write); metric writes_resume_s_after_template0 $W
check writes_resume_2a test "$W" != -1

say "2b: same situation with autovacuum = off (does anyone rescue template0?)"
stop $N; echo "autovacuum = off" >> $LAB/$N/postgresql.conf; start $N
q $P postgres "SHOW autovacuum"
blocker
consume_to_stop $P >/dev/null
check stop_reached_2b test "$(qs $P postgres "INSERT INTO u VALUES (0,0)")" = 54000
kill_blocker
vacuumdb -q -p $P --all --freeze -j 3 2>&1 | grep -vE 'bypassing|relfrozenxid or|^HINT|^You might|must be vacuumed' | head -3
state $P
W=$(wait_until 120 lt "qa $P postgres \"SELECT age(datfrozenxid) FROM pg_database WHERE datname='template0'\"" 2000000000)
echo "template0 rescued after $W s with autovacuum=off"; metric template0_rescue_s_av_off $W
check template0_rescued_even_with_autovacuum_off test "$W" != -1
check writes_resume_2b test "$(wait_until 30 can_write)" != -1

say "2c: last resort when no autovacuum worker can reach template0: single-user mode VACUUM"
blocker
consume_to_stop $P >/dev/null
check stop_reached_2c test "$(qs $P postgres "INSERT INTO u VALUES (0,0)")" = 54000
stop $N   # fast shutdown で blocker も終了。autovacuum ワーカーが救う前に止める
for db in postgres template1 template0; do
  echo "--- postgres --single $db: VACUUM (FREEZE)"
  echo "VACUUM (FREEZE);" | postgres --single -D $LAB/$N -c autovacuum=off -c log_min_messages=warning $db 2>&1 | grep -vE '^\s*$|stand-alone|backend>|bypassing|relfrozenxid or|maintenance_work_mem' | head -3
done
start $N
state $P
check template0_rescued_by_single_user test "$(qa $P postgres "SELECT age(datfrozenxid) < 100000000 FROM pg_database WHERE datname='template0'")" = t
check writes_resume_2c test "$(qs $P postgres "INSERT INTO u VALUES (-1,0)")" = OK
q $P postgres "SELECT count(*) FROM t"
log_audit $N 'database "template0" is not currently accepting connections'
finish
