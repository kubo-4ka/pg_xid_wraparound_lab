#!/bin/bash
# E14: 統計情報の喪失・陳腐化と周回防止の関係
#  14a クラッシュ (immediate shutdown) で累積統計がリセットされる (PG15+) -> 通常 autovacuum が dead tuple に気付かない
#      一方 relfrozenxid (カタログ) は失われない -> 周回防止だけは期限どおり来る
#  14b track_counts = off -> 通常 autovacuum は一切動かない (AutoVacuumingActive()=false) が、周回防止は動く
#  14c autovacuum = off 運用: 周回防止 VACUUM は ANALYZE をしない -> プランナ統計は古いまま。停止中は ANALYZE 自体が不可
source /vagrant/scripts/common.sh
P=5515; N=e14
new_cluster $N $P
for e in xid_wraparound pgstattuple; do q $P postgres "CREATE EXTENSION $e" >/dev/null; done
dead_phys(){ qa $P postgres "SELECT dead_tuple_count FROM pgstattuple('$1')"; }
dead_stat(){ qa $P postgres "SELECT n_dead_tup FROM pg_stat_user_tables WHERE relname='$1'"; }

say "14a: dead tuples, then crash before autovacuum gets to them"
q $P postgres "ALTER SYSTEM SET autovacuum = off"; qa $P postgres "SELECT pg_reload_conf()" >/dev/null
q $P postgres "CREATE TABLE d(id int primary key, pad text); INSERT INTO d SELECT g, repeat('d',100) FROM generate_series(1,1000000) g;"; q $P postgres "VACUUM (FREEZE, ANALYZE) d"; q $P postgres "DELETE FROM d WHERE id % 2 = 0"
sleep 1
echo "before crash: n_dead_tup(stats)=$(dead_stat d) dead_tuple_count(physical)=$(dead_phys d)"
crash $N
echo "after crash:  n_dead_tup(stats)=$(dead_stat d) dead_tuple_count(physical)=$(dead_phys d)"
check crash_resets_n_dead_tup test "$(dead_stat d)" -eq 0
q $P postgres "ALTER SYSTEM SET autovacuum = on"; qa $P postgres "SELECT pg_reload_conf()" >/dev/null
sleep 35   # naptime 10s x3
echo "35 s with autovacuum on: n_dead_tup=$(dead_stat d) physical=$(dead_phys d) last_autovacuum=$(qa $P postgres "SELECT coalesce(last_autovacuum::text,'never') FROM pg_stat_user_tables WHERE relname='d'")"
metric dead_phys_after_crash_35s $(dead_phys d)
check autovacuum_ignores_forgotten_dead_tuples test "$(dead_phys d)" -gt 400000
q $P postgres "SELECT relname, age(relfrozenxid) FROM pg_class WHERE relname='d'"
logmark $N
consume $P 210
sleep 15
echo "after +210M: physical dead=$(dead_phys d)  (anti-wraparound VACUUM removed them as a side effect)"
logsince $N | grep -A3 'wraparound of table "postgres.public.d"' | head -4
check antiwrap_still_on_schedule_after_crash test "$(qa $P postgres "SELECT age(relfrozenxid) < 200000000 FROM pg_class WHERE relname='d'")" = t

say "14b: track_counts = off"
stop $N; echo "track_counts = off" >> $LAB/$N/postgresql.conf; start $N
q $P postgres "SHOW track_counts"
q $P postgres "CREATE TABLE e(id int, pad text); INSERT INTO e SELECT g, 'e' FROM generate_series(1,300000) g; DELETE FROM e;"
logmark $N
sleep 25
NORMAL=$(logsince $N | grep -E 'automatic (vacuum|analyze) of table "postgres.public.e"' | grep -vc wraparound)
echo "normal autovacuum on e in 25 s: $NORMAL (300k dead tuples)"
check no_normal_autovacuum_with_track_counts_off test "$NORMAL" -eq 0
consume $P 210
sleep 15
AW=$(logsince $N | grep -c 'to prevent wraparound')
echo "anti-wraparound lines: $AW"
metric antiwrap_lines_track_counts_off $AW
check antiwrap_runs_with_track_counts_off test "$AW" -gt 0
sed -i '/^track_counts = off$/d' $LAB/$N/postgresql.conf; stop $N; start $N

say "14c: autovacuum = off; table grows 10x after its last ANALYZE; only anti-wraparound VACUUM runs"
q $P postgres "ALTER SYSTEM SET autovacuum = off"; qa $P postgres "SELECT pg_reload_conf()" >/dev/null
q $P postgres "CREATE TABLE s(id int, ts int); INSERT INTO s SELECT g, g FROM generate_series(1,100000) g; ANALYZE s;"
q $P postgres "INSERT INTO s SELECT g, g FROM generate_series(100001,1000000) g"
consume $P 210
sleep 15
q $P postgres "SELECT relname, reltuples::bigint, age(relfrozenxid), last_analyze, last_autoanalyze, last_autovacuum FROM pg_stat_user_tables JOIN pg_class USING (relname) WHERE relname='s'"
EST=$(qa $P postgres "EXPLAIN SELECT * FROM s WHERE ts > 500000" | grep -oE 'rows=[0-9]+' | head -1 | cut -d= -f2)
ACT=$(qa $P postgres "SELECT count(*) FROM s WHERE ts > 500000")
echo "planner estimate for ts > 500000: $EST rows, actual: $ACT rows (histogram still covers only 1..100000)"
metric stale_estimate_rows $EST; metric stale_actual_rows $ACT
check planner_estimate_badly_off test "$EST" -lt "$(( ACT / 10 ))"
check no_autoanalyze_happened test "$(qa $P postgres "SELECT last_autoanalyze IS NULL FROM pg_stat_user_tables WHERE relname='s'")" = t
log_audit $N
finish
