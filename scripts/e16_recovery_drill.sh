#!/bin/bash
# E16: 可視性崩壊からの復旧演習 (QA F-03 / #6)  ※隔離した使い捨てクラスタでのみ実施
#  表 r1, r2 に同一データ: 確定した 1000 行 (batch A) と ROLLBACK された 500 行 (batch B; 死んだタプル)
#  崩壊前に pg_dump でバックアップを取り、シングルユーザーモードで batch A が見えなくなるまで XID を進める
#  復旧手段を比較:
#    (1) 通常の VACUUM            -> 失敗するか
#    (2) pg_surgery 素朴版 (r1): 全タプルを heap_force_freeze -> ROLLBACK 済み行まで復活するか
#    (3) pg_surgery 慎重版 (r2): ヒントビットが「コミット済み」のタプルだけ凍結
#    (4) バックアップからの復元   -> (3) と内容が一致するか
source /vagrant/scripts/common.sh
P=5517; N=e16; D=$LAB/$N
new_cluster $N $P "autovacuum = off"
q $P postgres "CREATE DATABASE lab" >/dev/null
for e in xid_wraparound pageinspect amcheck pg_surgery; do q $P lab "CREATE EXTENSION $e" >/dev/null; done
for t in r1 r2; do
  q $P lab "CREATE TABLE $t(id int, batch text, payload text)" >/dev/null
  q $P lab "INSERT INTO $t SELECT g, 'A', md5(g::text) FROM generate_series(1,1000) g" >/dev/null
  q $P lab "BEGIN; INSERT INTO $t SELECT g, 'B', 'rolled back' FROM generate_series(1001,1500) g; ROLLBACK;" >/dev/null
  q $P lab "SELECT '$t' AS t, count(*) AS visible FROM $t"   # ヒントビットを設定させる
done
q $P lab "CREATE TABLE xa AS SELECT xmin::text::bigint AS x FROM r1 LIMIT 1" >/dev/null
psql -X -At -p $P -d lab -c "SELECT format('VACUUM (FREEZE) %s;', oid::regclass) FROM pg_class WHERE relkind IN ('r','m','t') AND relname NOT IN ('r1','r2')" | psql -X -q -p $P -d lab
for db in postgres template1; do vacuumdb -q -p $P --freeze -d $db; done
pg_dump -p $P -d lab -t r2 -f /tmp/e16_backup.sql
echo "backup taken: $(grep -cE '^[0-9]+	A	' /tmp/e16_backup.sql) rows of batch A"
q $P lab "CHECKPOINT" >/dev/null
stop $N
say "wrap in single-user mode until batch A is 'in the future' (xmin + 2^31 + 100M)"
echo "SELECT consume_xids_until(((SELECT x FROM xa) + 2247483648)::text::xid8)" | postgres --single -D $D -c autovacuum=off -c log_min_messages=error lab 2>&1 | grep -E 'ERROR|FATAL' | head -2
start $N
q $P lab "SELECT batch, count(*) FROM r2 GROUP BY 1"
check collapsed_batch_A_invisible test "$(qa $P lab "SELECT count(*) FROM r2")" -eq 0
check writes_stopped test "$(qs $P lab "CREATE TABLE z(i int)")" = 54000
q $P lab "SELECT count(*) AS amcheck_msgs FROM verify_heapam('r2')"

say "(1) plain VACUUM on the collapsed table"
V=$(qs $P lab "VACUUM r2"); echo "VACUUM r2 -> $V"; q $P lab "VACUUM r2" 2>&1 | grep -E 'ERROR|DETAIL|CONTEXT' | head -3
metric vacuum_sqlstate $V
check plain_vacuum_does_not_bring_rows_back test "$(qa $P lab "SELECT count(*) FROM r2")" -eq 0

tids(){ # <rel> <extra condition>
  echo "SELECT array_agg(format('(%s,%s)', b, lp)::tid) FROM generate_series(0, pg_relation_size('$1')/8192 - 1) b, heap_page_items(get_raw_page('$1', b::int)) WHERE lp_flags = 1 AND t_xmin IS NOT NULL $2"
}
say "(2) naive pg_surgery on r1: heap_force_freeze on EVERY tuple on the page"
q $P lab "SELECT heap_force_freeze('r1', ($(tids r1 '')))"
q $P lab "SELECT batch, count(*) FROM r1 GROUP BY 1 ORDER BY 1"
RB=$(qa $P lab "SELECT count(*) FROM r1 WHERE batch='B'")
metric naive_resurrected_rolled_back_rows $RB
check naive_surgery_resurrects_rolled_back_rows test "$RB" -eq 500

say "(3) careful pg_surgery on r2: only tuples whose xmin is hinted COMMITTED (0x0100) and not INVALID (0x0200)"
q $P lab "SELECT count(*) FILTER (WHERE t_infomask & 256 <> 0) AS hinted_committed, count(*) FILTER (WHERE t_infomask & 512 <> 0) AS hinted_invalid, count(*) FILTER (WHERE t_infomask & 768 = 0) AS no_hint FROM generate_series(0, pg_relation_size('r2')/8192 - 1) b, heap_page_items(get_raw_page('r2', b::int)) WHERE lp_flags = 1"
q $P lab "SELECT heap_force_freeze('r2', ($(tids r2 'AND t_infomask & 256 <> 0 AND t_infomask & 512 = 0')))"
q $P lab "SELECT batch, count(*) FROM r2 GROUP BY 1 ORDER BY 1"
check careful_surgery_restores_exactly_batch_A test "$(qa $P lab "SELECT count(*) FILTER (WHERE batch='A')||','||count(*) FILTER (WHERE batch='B') FROM r2")" = "1000,0"
q $P lab "SELECT count(*) AS amcheck_msgs_after FROM verify_heapam('r2')"
check amcheck_clean_after_surgery test "$(qa $P lab "SELECT count(*) FROM verify_heapam('r2')")" -eq 0

say "leave the STOP state: multi-user attempts first"
q $P lab "SELECT datname, datfrozenxid, age(datfrozenxid) FROM pg_database ORDER BY 1"
check datfrozenxid_in_the_future_negative_age test "$(qa $P lab "SELECT count(*) FROM pg_database WHERE age(datfrozenxid) < 0")" -ge 1
vacuumdb -p $P --all --freeze >/tmp/e16_vdb.txt 2>&1; VDB=$?
grep -E 'error|ERROR' /tmp/e16_vdb.txt | head -2
echo "vacuumdb --all --freeze exit=$VDB"
check multi_user_vacuumdb_fails test "$VDB" -ne 0
sleep 30
check anti_wraparound_workers_do_not_rescue_future_datfrozenxid test "$(qs $P lab "SELECT pg_current_xact_id()")" = 54000
# vac_truncate_clog(): 未来の datfrozenxid があると制限値の再計算を諦める
grep -m1 -A1 'have not been vacuumed in over 2 billion' $D/server.log
check limits_not_recomputed_warning_logged test "$(grep -c 'have not been vacuumed in over 2 billion' $D/server.log)" -ge 1
say "=> single-user mode: VACUUM (FREEZE) in every database (past wraparound this is the only way out)"
stop $N
for db in lab postgres template1 template0; do
  echo "--- postgres --single $db"
  echo "VACUUM (FREEZE);" | postgres --single -D $D -c autovacuum=off -c log_min_messages=error $db 2>&1 | grep -E 'ERROR|FATAL' | head -2
done
start $N
state $P
check writes_resume_after_single_user_vacuum test "$(qs $P lab "SELECT pg_current_xact_id()")" = OK
check repaired_r2_still_1000_rows test "$(qa $P lab "SELECT count(*) FROM r2")" -eq 1000
check r1_still_has_resurrected_rows test "$(qa $P lab "SELECT count(*) FROM r1 WHERE batch='B'")" -eq 500

say "(4) restore the pre-collapse backup into db 'restored' and compare with the surgically repaired r2"
q $P postgres "CREATE DATABASE restored" >/dev/null
psql -X -q -p $P -d restored -f /tmp/e16_backup.sql >/dev/null 2>&1
q $P restored "SELECT batch, count(*) FROM r2 GROUP BY 1"
DIFF=$(psql -X -At -p $P -d restored -c "COPY (SELECT id, batch, payload FROM r2 ORDER BY id) TO STDOUT" | md5sum | cut -c1-12)
REP=$(psql -X -At -p $P -d lab -c "COPY (SELECT id, batch, payload FROM r2 ORDER BY id) TO STDOUT" | md5sum | cut -c1-12)
echo "md5 restored=$DIFF repaired=$REP"
check backup_and_careful_surgery_identical test "$DIFF" = "$REP"
log_audit $N 'needs to be frozen|does not exist'
finish
