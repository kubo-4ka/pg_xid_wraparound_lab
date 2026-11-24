#!/bin/bash
# E3: autovacuum 停止設定の怖さ
#  3a autovacuum=off でも周回防止autovacuumは強制起動するか
#  3b テーブル単位 autovacuum_enabled=false
#  3c autovacuum=off + autovacuum_freeze_max_age=2e9(上限) + 3.6GB ヒープ -> 停止中もコスト遅延で走る
#  3d 対照: ヒープ 4GB 超 -> 走査途中 (4GB ごと) の failsafe 再判定でコスト遅延が外れるか (QA #3)
source /vagrant/scripts/common.sh
P=5503; N=e3
new_cluster $N $P "autovacuum = off"
q $P postgres "SHOW autovacuum"
q $P postgres "CREATE EXTENSION xid_wraparound"
q $P postgres "CREATE TABLE a(id int, pad text); INSERT INTO a SELECT g, repeat('x',100) FROM generate_series(1,1000000) g;"
q $P postgres "CREATE TABLE b(id int, pad text) WITH (autovacuum_enabled=false); INSERT INTO b SELECT g, repeat('x',100) FROM generate_series(1,1000000) g;"
logmark $N
say "3a/3b: consume 400M XIDs with autovacuum=off"
echo "csv,consumed_M,age_db,age_a,age_b,av_workers"
for i in $(seq 1 40); do
  qa $P postgres "SELECT consume_xids(10000000)" >/dev/null
  if [ $((i % 2)) -eq 0 ]; then
    echo "csv,$((i*10)),$(qa $P postgres "SELECT (SELECT age(datfrozenxid) FROM pg_database WHERE datname='postgres')||','||(SELECT age(relfrozenxid) FROM pg_class WHERE relname='a')||','||(SELECT age(relfrozenxid) FROM pg_class WHERE relname='b')||','||(SELECT count(*) FROM pg_stat_activity WHERE backend_type='autovacuum worker')")"
  fi
done
sleep 12
state $P
q $P postgres "SELECT relname, age(relfrozenxid), last_autovacuum, last_autoanalyze FROM pg_stat_user_tables JOIN pg_class USING(relname) ORDER BY 1"
echo "--- autovacuum log (autovacuum=off):"
logsince $N | grep -E 'automatic.*(public\.a|public\.b)' | head -4
AW=$(logsince $N | grep -c 'to prevent wraparound'); NW=$(logsince $N | grep -E 'automatic (vacuum|analyze) of' | grep -vc wraparound)
echo "anti-wraparound lines: $AW / normal (non-wraparound) autovacuum/analyze lines: $NW"
metric antiwrap_lines_3a $AW
check antiwrap_runs_with_autovacuum_off test "$AW" -gt 0
check reloption_disabled_table_b_also_frozen test "$(qa $P postgres "SELECT age(relfrozenxid) < 200000000 FROM pg_class WHERE relname='b'")" = t
check no_normal_autovacuum_or_analyze test "$NW" -eq 0

say "3c: autovacuum=off + autovacuum_freeze_max_age=2000000000 (max) + 20M-row table w/ index"
stop $N
echo "autovacuum_freeze_max_age = 2000000000" >> $LAB/$N/postgresql.conf
start $N
q $P postgres "SHOW autovacuum_freeze_max_age"
q $P postgres "CREATE TABLE big(id int, pad text); INSERT INTO big SELECT g, repeat('y',150) FROM generate_series(1,20000000) g; CREATE INDEX ON big(id);"
q $P postgres "SELECT pg_size_pretty(pg_relation_size('big')) AS heap, pg_size_pretty(pg_total_relation_size('big')) AS total"
metric big_heap_mb_3c $(qa $P postgres "SELECT pg_relation_size('big')/1048576")
q $P postgres "VACUUM (FREEZE) a"; q $P postgres "VACUUM (FREEZE) b"
logmark $N
run_to_stop(){ # 停止まで全速で消費しながら csv を出す
  echo "csv,elapsed_s,max_age,age_big,av_workers,msg"
  T0=$(now)
  for i in $(seq 1 260); do
    out=$(psql -X -At -p $P -d postgres -c "SELECT consume_xids(10000000)" 2>&1)
    msg=$(echo "$out" | grep -E '^(WARNING|ERROR)' | head -1)
    r=$(qa $P postgres "SELECT (SELECT max(age(datfrozenxid)) FROM pg_database)||','||(SELECT age(relfrozenxid) FROM pg_class WHERE relname='big')||','||(SELECT count(*) FROM pg_stat_activity WHERE backend_type='autovacuum worker')")
    if [ $((i % 10)) -eq 0 ] || [ -n "$msg" ]; then echo "csv,$(since $T0),$r,$msg"; fi
    echo "$out" | grep -q "^ERROR" && { echo "$out" | grep -E "ERROR|DETAIL" | head -2; echo "STOP reached at chunk $i"; break; }
  done
}
# 停止中: 書き込みが戻るまで待ち、進捗を 10 秒ごとに記録
watch_stop(){ # <tag>
  echo "prog,$1,elapsed_s,heap_blks_scanned,heap_blks_total,wait_event"
  TS=$(now)
  for i in $(seq 1 240); do
    r=$(qa $P postgres "SELECT p.heap_blks_scanned||','||p.heap_blks_total||','||coalesce(a.wait_event,'-') FROM pg_stat_progress_vacuum p JOIN pg_stat_activity a USING (pid) WHERE p.relid='big'::regclass")
    echo "prog,$1,$(since $TS),${r:-done}"
    [ "$(qs $P postgres "INSERT INTO a VALUES (0,'x')")" = OK ] && { STOPDUR=$(since $TS); echo "writes accepted again after $STOPDUR s in STOP"; break; }
    sleep 10
  done
}
say "consume at full speed and watch how close we get to the stop limit"
run_to_stop
check stop_reached_3c test "$(qs $P postgres "INSERT INTO a VALUES (0,'x')")" = 54000
say "STOP state: autovacuum worker is still on big? wait for self-recovery (poll 10s, max 40min)"
q $P postgres "SELECT pid, now()-xact_start AS dur, wait_event, query FROM pg_stat_activity WHERE backend_type='autovacuum worker'"
watch_stop 3c
metric stop_duration_s_3c $STOPDUR
state $P
logsince $N | grep -A13 'wraparound of table "postgres.public.big"' | grep -E 'automatic|pages:|elapsed|failsafe|read rate' | head -12 | tee /tmp/e3c.log
metric vacuum_elapsed_s_3c $(grep -oE 'elapsed: [0-9.]+' /tmp/e3c.log | tail -1 | awk '{print $2}')
metric vacuum_read_mbps_3c $(grep -oE 'avg read rate: [0-9.]+' /tmp/e3c.log | tail -1 | awk '{print $4}')
FS3C=$(logsince $N | grep -c 'maintenance of table "postgres.public.big" as a failsafe')
metric failsafe_on_big_3c $FS3C
check no_failsafe_on_big_below_4GB test "$FS3C" -eq 0
log_audit $N
drop_cluster $N

say "3d: control: same settings but heap > 4GB (failsafe is re-checked every 4GB of heap scanned)"
# 待ち時間短縮のため 3d はコスト上限を 5 倍 (1000) にする。比較対象は '途中で failsafe に切り替わるか' のみ
N=e3d
new_cluster $N $P "autovacuum = off" "autovacuum_freeze_max_age = 2000000000" "autovacuum_vacuum_cost_limit = 1000"
q $P postgres "CREATE EXTENSION xid_wraparound"
q $P postgres "CREATE TABLE a(id int, pad text); INSERT INTO a VALUES (1,'x');"; q $P postgres "VACUUM (FREEZE) a"
q $P postgres "CREATE TABLE big(id int, pad text); INSERT INTO big SELECT g, repeat('y',150) FROM generate_series(1,30000000) g; CREATE INDEX ON big(id);"
q $P postgres "SELECT pg_size_pretty(pg_relation_size('big')) AS heap, pg_size_pretty(pg_total_relation_size('big')) AS total, pg_relation_size('big')/8192 AS pages"
metric big_heap_mb_3d $(qa $P postgres "SELECT pg_relation_size('big')/1048576")
check heap_over_4GB test "$(qa $P postgres "SELECT pg_relation_size('big') > 4294967296")" = t
logmark $N
run_to_stop
check stop_reached_3d test "$(qs $P postgres "INSERT INTO a VALUES (0,'x')")" = 54000
watch_stop 3d
metric stop_duration_s_3d $STOPDUR
logsince $N | grep -B1 -A3 'maintenance of table "postgres.public.big" as a failsafe' | head -6
logsince $N | grep -A13 'wraparound of table "postgres.public.big"' | grep -E 'automatic|pages:|elapsed|failsafe|read rate' | head -8 | tee /tmp/e3d.log
FS3D=$(logsince $N | grep -c 'maintenance of table "postgres.public.big" as a failsafe')
metric failsafe_on_big_3d $FS3D
metric vacuum_elapsed_s_3d $(grep -oE 'elapsed: [0-9.]+' /tmp/e3d.log | tail -1 | awk '{print $2}')
check failsafe_triggers_mid_scan_over_4GB test "$FS3D" -ge 1
state $P
log_audit $N
finish
