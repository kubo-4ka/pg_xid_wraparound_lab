#!/bin/bash
# E11: ロングトランザクションの変種 — 「どこまで」凍結を止めるのか
#  11a 別データベースのロングトランザクション: 自 DB のユーザ表は凍結できるか? 共有カタログは? datfrozenxid は?
#  11b XID を持たない長時間の単一 SELECT (READ COMMITTED の集計クエリ等): 実行中だけ xmin を保持する
#  11c 同じ SELECT がレプリカ (hot_standby_feedback=on) で走った場合 -> プライマリの凍結が止まる (E4 の補足)
source /vagrant/scripts/common.sh
P=5512; N=e11
new_cluster $N $P
q $P postgres "CREATE EXTENSION xid_wraparound"
q $P postgres "CREATE DATABASE batchdb"
q $P postgres "CREATE TABLE t(id int, pad text); INSERT INTO t SELECT g, 'x' FROM generate_series(1,100000) g;"
shared_ages(){ q $P postgres "SELECT c.relname, c.relisshared, age(c.relfrozenxid) FROM pg_class c WHERE c.relname IN ('t','pg_class','pg_database','pg_authid','pg_shdepend') ORDER BY 2, 1"; }

say "11a: long transaction (with XID) in ANOTHER database (batchdb), consume 400M in postgres"
PGAPPNAME=other_db_batch psql -X -p $P -d batchdb -c "BEGIN; SELECT pg_current_xact_id(); SELECT pg_sleep(86400);" >/dev/null 2>&1 &
sleep 2
consume $P 400
sleep 15
shared_ages
state $P
check other_db_tx_does_not_block_local_user_table test "$(qa $P postgres "SELECT age(relfrozenxid) < 200000000 FROM pg_class WHERE relname='t'")" = t
check other_db_tx_blocks_shared_catalogs test "$(qa $P postgres "SELECT age(relfrozenxid) > 350000000 FROM pg_class WHERE relname='pg_database'")" = t
check datfrozenxid_of_postgres_held_back test "$(qa $P postgres "SELECT age(datfrozenxid) > 350000000 FROM pg_database WHERE datname='postgres'")" = t
metric other_db_postgres_datfrozen_age $(qa $P postgres "SELECT age(datfrozenxid) FROM pg_database WHERE datname='postgres'")
metric other_db_local_table_age $(qa $P postgres "SELECT age(relfrozenxid) FROM pg_class WHERE relname='t'")
diag $P | head -8
qa $P postgres "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name='other_db_batch'" >/dev/null
W=$(wait_until 120 lt "maxage $P" 250000000); echo "recovered in $W s"

say "11b: one long-running SELECT (READ COMMITTED, no XID) — e.g. a 'monthly report' query"
PGAPPNAME=report_query psql -X -p $P -d postgres -c "SELECT count(*) FROM t, pg_sleep(86400)" >/dev/null 2>&1 &
sleep 2
q $P postgres "SELECT application_name, state, backend_xid, backend_xmin, age(backend_xmin) FROM pg_stat_activity WHERE application_name='report_query'"
consume $P 300
sleep 12
state $P
check long_select_holds_back test "$(maxage $P)" -gt 250000000
qa $P postgres "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name='report_query'" >/dev/null
W=$(wait_until 120 lt "maxage $P" 250000000); echo "recovered in $W s after cancelling the query"
check cancel_query_is_enough test "$W" != -1

say "11c: the same report query on a hot standby with hot_standby_feedback=on"
# 注: consume_xids() はサブトランザクションで大量の XID を割り当てるため、スタンバイの再生が
#     'FATAL: too many KnownAssignedXids' で停止する (試験モジュール固有)。11c は pgbench の通常トランザクションで XID を進める
S=e11s; SP=5522
pg_ctl -D $LAB/$S stop -m immediate >/dev/null 2>&1; rm -rf $LAB/$S
timeout 300 pg_basebackup -p $P -D $LAB/$S -R -C -S standby_slot -X stream --checkpoint=fast 2>&1 | tail -1
printf "port = $SP\nhot_standby_feedback = on\n" >> $LAB/$S/postgresql.conf
start $S; CLUSTERS+=($S)
sleep 3
printf "INSERT INTO t VALUES (0, 'w');\n" > /tmp/e11_ins.sql
cutoff_age(){ # primary で VACUUM (FREEZE) t した直後の age(relfrozenxid) (= 凍結の境界がどれだけ古いか)
  qa $P postgres "VACUUM (FREEZE) t" >/dev/null; qa $P postgres "SELECT age(relfrozenxid) FROM pg_class WHERE relname='t'"
}
work(){ pgbench -n -p $P -c 4 -T 10 -f /tmp/e11_ins.sql postgres 2>&1 | grep -oE 'actually processed: [0-9]+'; }
slot(){ q $P postgres "SELECT slot_name, active, xmin, age(xmin) FROM pg_replication_slots"; }
# スタンバイの feedback (wal_receiver_status_interval=10s) が反映されるまで待つ: 境界が N 未満になるまで最大 60 秒
settle(){ for i in $(seq 1 12); do qa $P postgres "CHECKPOINT" >/dev/null; sleep 5; a=$(cutoff_age); [ "$a" -lt "$1" ] && break; done; echo $a; }
echo "--- phase 1: standby idle (no query)"
work; A0=$(settle 100); slot
echo "frozen-age after VACUUM (FREEZE), standby idle: $A0"
metric standby_idle_frozen_age $A0
echo "--- phase 2: a long report query on the standby"
PGAPPNAME=report_on_standby psql -X -p $SP -d postgres -c "SELECT count(*) FROM t, pg_sleep(86400)" >/dev/null 2>&1 &
sleep 12
work; work
A1=$(cutoff_age); slot
echo "frozen-age after VACUUM (FREEZE), standby query running: $A1"
q $P postgres "VACUUM (FREEZE, VERBOSE) t" 2>&1 | grep -E 'removable cutoff'
metric standby_query_frozen_age $A1
check standby_query_holds_back_primary_freeze test "$A1" -gt $(( A0 + 1000 ))
echo "--- on the primary it is visible only as the slot's xmin (or the walsender's backend_xmin without a slot):"
q $P postgres "SELECT backend_type, application_name, backend_xmin FROM pg_stat_activity WHERE backend_type='walsender'"
diag $P | grep -E 'kind|replication_slot|backend_xmin'
echo "--- phase 3: cancel the standby query"
qa $SP postgres "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name='report_on_standby'" >/dev/null
A2=$(settle 100); slot
echo "frozen-age after cancelling the standby query: $A2"
metric standby_query_frozen_age_after_cancel $A2
check freeze_advances_after_standby_cancel test "$A2" -lt 100
log_audit $N "walsender|replication"
log_audit $S "walreceiver|replication|canceling statement|connect to the primary"
finish
