#!/bin/bash
# E4: 不要なレプリケーションスロットの残置
#  - 物理スロット(hot_standby_feedback=on の standby を撤去) -> slot.xmin が残る
#  - 論理スロット(サブスクライバ撤去) -> slot.catalog_xmin が残る
#  - WAL保持だけの物理スロット(feedback無し) -> xmin は NULL (XID的には無害)
#  - PG18 idle_replication_slot_timeout による自動無効化
source /vagrant/scripts/common.sh
P=5504; N=e4; SP=5514; S=e4s
new_cluster $N $P
q $P postgres "CREATE EXTENSION xid_wraparound"
q $P postgres "CREATE TABLE t(id int primary key, pad text); INSERT INTO t SELECT g, repeat('x',100) FROM generate_series(1,500000) g;"
say "build standby with slot + hot_standby_feedback"
pg_ctl -D $LAB/$S stop -m immediate >/dev/null 2>&1; rm -rf $LAB/$S
timeout 300 pg_basebackup -p $P -D $LAB/$S -R -C -S standby1_slot -X stream --checkpoint=fast -v 2>&1
cat >> $LAB/$S/postgresql.conf <<C
port = $SP
hot_standby_feedback = on
C
start $S
q $P postgres "SELECT pg_create_logical_replication_slot('forgotten_sub', 'test_decoding')"
q $P postgres "SELECT pg_create_physical_replication_slot('wal_only_slot', true)"
q $SP postgres "SELECT pg_sleep(1), count(*) FROM t" >/dev/null
sleep 3
q $P postgres "SELECT slot_name, slot_type, active, xmin, catalog_xmin, restart_lsn FROM pg_replication_slots ORDER BY 1"
say "decommission standby (stop it) but forget to drop its slot; also restart primary"
stop $S
stop $N; start $N
q $P postgres "SELECT slot_name, active, xmin, catalog_xmin, age(xmin) xmin_age, age(catalog_xmin) cat_age FROM pg_replication_slots ORDER BY 1"
check physical_slot_xmin_survives_restart test "$(qa $P postgres "SELECT xmin IS NOT NULL FROM pg_replication_slots WHERE slot_name='standby1_slot'")" = t
check logical_slot_catalog_xmin_survives_restart test "$(qa $P postgres "SELECT catalog_xmin IS NOT NULL FROM pg_replication_slots WHERE slot_name='forgotten_sub'")" = t
check wal_only_slot_has_no_xmin test "$(qa $P postgres "SELECT xmin IS NULL AND catalog_xmin IS NULL FROM pg_replication_slots WHERE slot_name='wal_only_slot'")" = t
logmark $N
say "consume until STOP (autovacuum on, default settings)"
echo "csv,consumed_M,max_age,age_t,age_pg_class,msg"
for i in $(seq 1 300); do
  out=$(psql -X -At -p $P -d postgres -c "SELECT consume_xids(10000000)" 2>&1)
  msg=$(echo "$out" | grep -E '^(WARNING|ERROR)' | head -1)
  r=$(qa $P postgres "SELECT (SELECT max(age(datfrozenxid)) FROM pg_database)||','||(SELECT age(relfrozenxid) FROM pg_class WHERE relname='t')||','||(SELECT age(relfrozenxid) FROM pg_class WHERE relname='pg_class')")
  if [ $((i % 20)) -eq 0 ] || [ -n "$msg" ] && [ $((i % 2)) -eq 0 -o -n "$(echo $msg|grep ERROR)" ]; then echo "csv,$((i*10)),$r,$msg"; fi
  echo "$out" | grep -q '^ERROR' && break
done
state $P
check stop_reached_with_slots test "$(qs $P postgres "INSERT INTO t VALUES (0,'x')")" = 54000
metric stop_age $(maxage $P)
q $P postgres "SELECT slot_name, active, xmin, catalog_xmin, age(xmin) xmin_age, age(catalog_xmin) cat_age, wal_status FROM pg_replication_slots ORDER BY 1"
echo "--- VACUUM VERBOSE t (user table) with slots present"
q $P postgres "VACUUM (VERBOSE) t" | grep -E 'WARNING|HINT|removable cutoff|new relfrozenxid' | head -5
echo "--- autovacuum log hint"
logsince $N | grep -m2 -A1 'far in the past'

say "RECOVERY step1: drop only the physical slot (standby1_slot)"
q $P postgres "SELECT pg_drop_replication_slot('standby1_slot')"
vacuumdb -p $P --all 2>&1 | grep -vE 'bypassing|relfrozenxid or|^HINT|^You might' | sort | uniq -c
sleep 3
state $P
q $P postgres "SELECT c.oid::regclass rel, age(relfrozenxid) FROM pg_class c WHERE relkind='r' ORDER BY 2 DESC, 1 LIMIT 4"
q $P postgres "INSERT INTO t VALUES (0,'x')" | head -1
check still_stopped_after_dropping_physical_only test "$(qs $P postgres "INSERT INTO t VALUES (0,'x')")" = 54000
check catalogs_pinned_by_logical_slot test "$(qa $P postgres "SELECT count(*) FROM pg_class WHERE relkind='r' AND relnamespace='pg_catalog'::regnamespace AND age(relfrozenxid) > 2000000000")" -gt 0
check user_table_t_frozen_after_physical_drop test "$(qa $P postgres "SELECT age(relfrozenxid) < 200000000 FROM pg_class WHERE relname='t'")" = t
say "RECOVERY step2: drop the logical slot too"
q $P postgres "SELECT pg_drop_replication_slot('forgotten_sub')"
vacuumdb -p $P --all 2>&1 | grep -vE 'bypassing|relfrozenxid or|^HINT|^You might' | sort | uniq -c
for i in $(seq 1 30); do a=$(qa $P postgres "SELECT max(age(datfrozenxid)) FROM pg_database"); [ "$a" -lt 2000000000 ] && break; sleep 2; done
sleep 2
state $P
q $P postgres "INSERT INTO t VALUES (0,'x')" | head -1
check writes_resume_after_dropping_logical test "$(qs $P postgres "INSERT INTO t VALUES (-1,'x')")" = OK

say "PG18 countermeasure: idle_replication_slot_timeout"
q $P postgres "ALTER SYSTEM SET idle_replication_slot_timeout = '30s'" ; q $P postgres "SELECT pg_reload_conf()" >/dev/null
q $P postgres "SELECT name, setting, unit FROM pg_settings WHERE name='idle_replication_slot_timeout'"
q $P postgres "SELECT pg_create_logical_replication_slot('forgotten_sub2', 'test_decoding')" >/dev/null
q $P postgres "SELECT slot_name, active, catalog_xmin, inactive_since, invalidation_reason FROM pg_replication_slots"
sleep 35; q $P postgres "CHECKPOINT"
q $P postgres "SELECT slot_name, active, catalog_xmin, inactive_since, invalidation_reason FROM pg_replication_slots"
logsince $N | grep -m2 -A1 'invalidating'
check idle_timeout_invalidates_slot test "$(qa $P postgres "SELECT invalidation_reason FROM pg_replication_slots WHERE slot_name='forgotten_sub2'")" = idle_timeout
log_audit $N "walsender|walreceiver|replication"
log_audit $S "walsender|walreceiver|replication|connect to the primary"
finish
