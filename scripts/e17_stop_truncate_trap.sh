#!/bin/bash
# E17: 停止中の「データベース全体 VACUUM」(エラーの HINT が勧める操作) が、無関係な若い表の末尾切り詰めで失敗する罠
#  仕組み (PG18 ソース):
#   - VACUUM は末尾の空ページを切り詰めるとき AccessExclusiveLock を取る (vacuumlazy.c lazy_truncate_heap)
#   - wal_level >= replica では AccessExclusiveLock 取得時にスタンバイ向け記録のため XID が割り当てられる
#     (lock.c -> standby.c LogAccessExclusiveLockPrepare)。停止中はここで 54000
#   - ただし failsafe 発動中の表 (age > vacuum_failsafe_age) は切り詰め自体を省略する (vacuumlazy.c)
#  => 停止の原因とは別の、age が 16 億未満で末尾に削除行がある表が 1 つあると、DB 全体 VACUUM / vacuumdb はそこで中断する
#  停止の原因: autovacuum=off + autovacuum_freeze_max_age=20億 + cost_limit=10 で、周回防止 VACUUM が這うように遅い (E3c の誇張版)
source /vagrant/scripts/common.sh
P=5518; N=e17
new_cluster $N $P "autovacuum = off" "autovacuum_freeze_max_age = 2000000000" "autovacuum_vacuum_cost_limit = 10"
q $P postgres "SHOW wal_level"
q $P postgres "CREATE EXTENSION xid_wraparound"
q $P postgres "CREATE TABLE slow(id int, pad text); INSERT INTO slow SELECT g, repeat('s',100) FROM generate_series(1,2000000) g;"
q $P postgres "CREATE TABLE u(i int)"
say "t=1.0B: create a young table 'tail'; t=1.9B: delete its newest half (removable dead tuples at the END of the heap)"
consume $P 1000
q $P postgres "CREATE TABLE tail(id int, pad text); INSERT INTO tail SELECT g, repeat('t',100) FROM generate_series(1,1000000) g;"; q $P postgres "VACUUM (FREEZE) tail"
consume $P 900
q $P postgres "DELETE FROM tail WHERE id > 500000"
consume_to_stop $P >/dev/null
check stop_reached test "$(qs $P postgres "INSERT INTO u VALUES (1)")" = 54000
q $P postgres "SELECT relname, age(relfrozenxid), pg_size_pretty(pg_relation_size(oid)) FROM pg_class WHERE relname IN ('slow','tail')"
q $P postgres "SELECT relid::regclass, phase, heap_blks_scanned, heap_blks_total FROM pg_stat_progress_vacuum"
metric tail_age_at_stop $(qa $P postgres "SELECT age(relfrozenxid) FROM pg_class WHERE relname='tail'")
check tail_is_younger_than_failsafe test "$(qa $P postgres "SELECT age(relfrozenxid) < 1600000000 FROM pg_class WHERE relname='tail'")" = t

say "the HINT says: 'Execute a database-wide VACUUM in that database.'  (SKIP_LOCKED: the crawling autovacuum holds 'slow')"
q $P postgres "VACUUM (SKIP_LOCKED)" 2>&1 | grep -E '^(ERROR|CONTEXT|WARNING:  skipping)' | head -3
V=$(qs $P postgres "VACUUM (SKIP_LOCKED)"); echo "database-wide VACUUM -> $V"
check database_wide_vacuum_fails_54000 test "$V" = 54000
q $P postgres "VACUUM tail" 2>&1 | grep -E '^(ERROR|CONTEXT)' | head -2
check vacuum_tail_fails_in_truncate_phase test "$(q $P postgres "VACUUM tail" 2>&1 | grep -c 'while truncating relation')" -ge 1
vacuumdb -p $P -d postgres -t tail >/dev/null 2>&1; VDB=$?
vacuumdb -p $P -d postgres -t tail --no-truncate >/dev/null 2>&1; VDBNT=$?
echo "vacuumdb -t tail: exit=$VDB / with --no-truncate: exit=$VDBNT"
check vacuumdb_fails test "$VDB" -ne 0
check vacuumdb_no_truncate_succeeds test "$VDBNT" -eq 0
check alter_table_vacuum_truncate_off_impossible test "$(qs $P postgres "ALTER TABLE tail SET (vacuum_truncate = false)")" = 54000
V=$(qs $P postgres "VACUUM (SKIP_LOCKED, TRUNCATE false)"); echo "database-wide VACUUM (TRUNCATE false) -> $V"
check database_wide_vacuum_truncate_false_succeeds test "$V" = OK

say "the real cause is the crawling anti-wraparound autovacuum: speed it up by reload (PG16+)"
check alter_system_works_in_stop test "$(qs $P postgres "ALTER SYSTEM SET autovacuum_vacuum_cost_limit = -1")" = OK; qa $P postgres "SELECT pg_reload_conf()" >/dev/null
q $P postgres "ALTER SYSTEM SET autovacuum_vacuum_cost_delay = 0"; qa $P postgres "SELECT pg_reload_conf()" >/dev/null
can_write(){ test "$(qs $P postgres "INSERT INTO u VALUES (1)")" = OK; }
W=$(wait_until 300 can_write); echo "writes resumed after $W s"; metric writes_resume_after_reload_s $W
check writes_resume test "$W" != -1
state $P
say "afterwards a normal VACUUM truncates the empty tail"
q $P postgres "SELECT pg_size_pretty(pg_relation_size('tail')) AS before"
check vacuum_tail_ok_after_recovery test "$(qs $P postgres "VACUUM tail")" = OK
q $P postgres "SELECT pg_size_pretty(pg_relation_size('tail')) AS after"
log_audit $N
finish
