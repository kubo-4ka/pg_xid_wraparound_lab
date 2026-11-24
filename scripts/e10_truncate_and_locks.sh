#!/bin/bash
# E10: TRUNCATE の繰り返しとロック競合
#  10a TRUNCATE+再投入を高頻度で繰り返す: XID 消費 / カタログ (pg_class) の膨張 / relfrozenxid はどう動くか
#  10b TRUNCATE 後の relfrozenxid は RecentXmin (= 実行中で XID を持つトランザクションの最古) になる:
#      スナップショットだけの古いセッションでは古くならないが、XID を持つロングトランザクションがあると古いまま
#  10c 通常の autovacuum はロック競合で自らキャンセルされる -> 定期的な DDL/LOCK で永遠に完了しない
#  10d 周回防止 autovacuum はキャンセルされない -> TRUNCATE が待たされ、その後ろの SELECT まで行列になる
#  10e DBA が周回防止 autovacuum をキャンセルしても、すぐ再起動する
source /vagrant/scripts/common.sh
P=5511; N=e10
# 周回防止 VACUUM を数分続かせるため、autovacuum のコスト上限を既定の 1/4 (50) にする
new_cluster $N $P "log_lock_waits = on" "deadlock_timeout = 1s" "autovacuum_vacuum_cost_limit = 50"
nx(){ qa $P postgres "SELECT pg_snapshot_xmax(pg_current_snapshot())::text"; }
q $P postgres "CREATE EXTENSION xid_wraparound"

say "10a: TRUNCATE + reload 100 rows, 4 clients, 30 s"
q $P postgres "CREATE TABLE tq(id int, pad text); INSERT INTO tq SELECT g, 'x' FROM generate_series(1,100) g;"
q $P postgres "SELECT pg_size_pretty(pg_relation_size('pg_class')) pg_class_before, (SELECT n_dead_tup FROM pg_stat_sys_tables WHERE relname='pg_class') dead_before"
printf "TRUNCATE tq;\nINSERT INTO tq SELECT g, 'x' FROM generate_series(1,100) g;\n" > /tmp/e10_tr.sql
A=$(nx); OUT=$(pgbench -p $P -n -c 1 -T 30 -f /tmp/e10_tr.sql postgres 2>&1); B=$(nx)
TPS=$(echo "$OUT" | grep -oE 'tps = [0-9.]+' | awk '{print int($3)}')
echo "TRUNCATE+INSERT tx/s=$TPS, XIDs consumed=$((B-A))"
metric truncate_tps $TPS; metric truncate_xids $((B-A))
q $P postgres "SELECT pg_size_pretty(pg_relation_size('pg_class')) pg_class_after, (SELECT n_dead_tup FROM pg_stat_sys_tables WHERE relname='pg_class') dead_after, (SELECT autovacuum_count FROM pg_stat_sys_tables WHERE relname='pg_class') pg_class_autovacuums"
q $P postgres "SELECT relname, age(relfrozenxid) FROM pg_class WHERE relname='tq'"
check truncate_resets_relfrozenxid_normally test "$(qa $P postgres "SELECT age(relfrozenxid) < 1000 FROM pg_class WHERE relname='tq'")" = t

tq_age(){ qa $P postgres "SELECT age(relfrozenxid) FROM pg_class WHERE relname='tq'"; }
say "10b-1: TRUNCATE while an old REPEATABLE READ snapshot (no XID) has been idle for 300M XIDs"
( printf "BEGIN ISOLATION LEVEL REPEATABLE READ;\nSELECT 1;\n\\\\! sleep 100000\n" | PGAPPNAME=old_snapshot psql -X -p $P -d postgres >/dev/null 2>&1 ) 2>/dev/null &
sleep 2
q $P postgres "SELECT application_name, backend_xid, backend_xmin FROM pg_stat_activity WHERE application_name='old_snapshot'"
consume $P 300
q $P postgres "TRUNCATE tq"
AGE=$(tq_age); echo "age(relfrozenxid) of tq right after TRUNCATE: $AGE"
metric truncate_age_under_old_snapshot $AGE
check truncate_resets_even_under_snapshot_only_holder test "$AGE" -lt 50000000
qa $P postgres "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name='old_snapshot'" >/dev/null
pkill -f 'sleep 100000' 2>/dev/null
say "10b-2: TRUNCATE while a transaction HOLDING AN XID has been open for 300M XIDs"
PGAPPNAME=old_xid psql -X -p $P -d postgres -c "BEGIN; SELECT pg_current_xact_id(); SELECT pg_sleep(86400);" >/dev/null 2>&1 &
sleep 2
consume $P 300
q $P postgres "TRUNCATE tq"
AGE=$(tq_age); echo "age(relfrozenxid) of tq right after TRUNCATE: $AGE"
metric truncate_age_under_old_xid $AGE
check truncate_keeps_old_relfrozenxid_under_xid_holder test "$AGE" -gt 290000000
qa $P postgres "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name='old_xid'" >/dev/null
sleep 1
q $P postgres "TRUNCATE tq"
check truncate_after_holder_gone_resets test "$(tq_age)" -lt 50000000
q $P postgres "VACUUM (FREEZE)" >/dev/null

# 周回防止 autovacuum の表示は 'autovacuum: VACUUM [ANALYZE] public.big (to prevent wraparound)'
av_on_big(){ [ -n "$(qa $P postgres "SELECT 1 FROM pg_stat_activity WHERE query LIKE 'autovacuum: VACUUM%public.big (to prevent wraparound)%'")" ]; }

say "10c: plain autovacuum vs a job that takes a SHARE lock every 3 s (e.g. batch / DDL / LOCK TABLE)"
q $P postgres "CREATE TABLE big(id int primary key, pad text); INSERT INTO big SELECT g, repeat('b',120) FROM generate_series(1,4000000) g;"; q $P postgres "VACUUM (FREEZE, ANALYZE) big"
q $P postgres "SELECT pg_size_pretty(pg_total_relation_size('big'))"
q $P postgres "DELETE FROM big WHERE id % 3 = 0"   # 133 万 dead tuples (全ページ) -> 通常 autovacuum の対象
logmark $N
# ジョブは 10d の周回防止 VACUUM が始まるまで続ける (/tmp/e10_stop で停止)
rm -f /tmp/e10_stop
( while [ ! -f /tmp/e10_stop ]; do PGAPPNAME=lock_job psql -X -q -p $P -d postgres -c "BEGIN; LOCK TABLE big IN SHARE MODE; SELECT pg_sleep(0.5); COMMIT;" >/dev/null 2>&1; sleep 3; done ) 2>/dev/null &
LJ=$!
sleep 90
CANCELS=$(logsince $N | grep -c 'canceling autovacuum task')
echo "autovacuum cancellations in 90 s: $CANCELS"
logsince $N | grep -m2 -B1 -A1 'canceling autovacuum task'
q $P postgres "SELECT n_dead_tup, last_autovacuum, autovacuum_count FROM pg_stat_user_tables WHERE relname='big'"
metric plain_autovacuum_cancels_90s $CANCELS
check plain_autovacuum_gets_canceled test "$CANCELS" -ge 1
check dead_tuples_not_removed test "$(qa $P postgres "SELECT n_dead_tup > 1000000 FROM pg_stat_user_tables WHERE relname='big'")" = t

say "10d: once big is past autovacuum_freeze_max_age, the SAME job collides with an anti-wraparound autovacuum"
logmark $N
consume $P 210
W=$(wait_until 180 av_on_big); echo "anti-wraparound autovacuum on big started $W s after +210M"
sleep 8
echo "--- lock_job is now stuck behind the anti-wraparound autovacuum:"
q $P postgres "SELECT pid, application_name, backend_type, wait_event_type, wait_event, pg_blocking_pids(pid) AS blocked_by, left(query,60) AS query FROM pg_stat_activity WHERE wait_event_type='Lock' OR backend_type='autovacuum worker' ORDER BY backend_start"
check lock_job_blocked_by_antiwrap test "$(qa $P postgres "SELECT count(*) FROM pg_stat_activity WHERE application_name='lock_job' AND wait_event_type='Lock'")" -eq 1
touch /tmp/e10_stop
T0=$(now)
PGAPPNAME=truncate_job psql -X -q -p $P -d postgres -c "TRUNCATE big" >/dev/null 2>&1 &
TJ=$!; sleep 2
PGAPPNAME=app_reader psql -X -q -p $P -d postgres -c "SELECT count(*) FROM big WHERE id < 100" >/dev/null 2>&1 &
RJ=$!; sleep 3
echo "--- lock queue: autovacuum <- lock_job <- TRUNCATE <- plain SELECT"
q $P postgres "SELECT pid, application_name, wait_event_type, wait_event, pg_blocking_pids(pid) AS blocked_by, left(query,50) AS query FROM pg_stat_activity WHERE wait_event_type='Lock' ORDER BY backend_start"
Q=$(qa $P postgres "SELECT count(*) FROM pg_stat_activity WHERE application_name='app_reader' AND wait_event_type='Lock'")
check plain_select_queued_behind_truncate test "$Q" -eq 1
echo "--- log_lock_waits:"; logsince $N | grep -m2 -A2 'still waiting'
check antiwrap_autovacuum_not_canceled test "$(logsince $N | grep -A2 'canceling autovacuum task' | grep -c 'to prevent wraparound')" -eq 0
wait $TJ; TW=$(since $T0); wait $RJ; wait $LJ
echo "TRUNCATE (and the SELECT behind it) waited $TW s"
metric truncate_wait_s_behind_antiwrap $TW
LJW=$(logsince $N | grep -oE 'acquired ShareLock on relation [0-9]+ of database [0-9]+ after [0-9.]+ ms' | awk '{print $(NF-1)}' | sort -n | tail -1)
echo "longest wait of the periodic lock job (log_lock_waits): $LJW ms"
metric lock_job_max_wait_s $(echo "scale=1; ${LJW:-0} / 1000" | bc)
logsince $N | grep -A12 'wraparound of table "postgres.public.big"' | grep -E 'automatic|pages:|tuples:|index scans|elapsed' | head -5

say "10e: what if the DBA cancels the anti-wraparound autovacuum?"
q $P postgres "DROP TABLE big; CREATE TABLE big(id int primary key, pad text) WITH (autovacuum_enabled = false); INSERT INTO big SELECT g, repeat('b',120) FROM generate_series(1,4000000) g;"
consume $P 210
W=$(wait_until 180 av_on_big)
logmark $N
AV=$(qa $P postgres "SELECT pid FROM pg_stat_activity WHERE query LIKE 'autovacuum: VACUUM%public.big (to prevent wraparound)%'")
q $P postgres "SELECT pg_cancel_backend($AV)"
sleep 2; logsince $N | grep -m2 -E 'canceling statement|ERROR|CONTEXT'
W=$(wait_until 180 av_on_big)
echo "anti-wraparound autovacuum on big restarted after $W s"
metric antiwrap_restart_after_cancel_s $W
check antiwrap_restarts_after_cancel test "$W" != -1
log_audit $N
finish
