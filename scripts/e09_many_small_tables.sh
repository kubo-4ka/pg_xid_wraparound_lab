#!/bin/bash
# E9: 小規模テーブルの量産 (マルチテナントのテナント毎テーブル、パーティション乱立を想定)
#  - 2万表を一度に作ると relfrozenxid が揃い、2億で「一斉に」周回防止 VACUUM の対象になる
#  A 周回防止 autovacuum の処理能力 (表/秒) を workers=3 (既定) と 6 で測る
#  B 全速消費と競争させ、阻害要因なしでも警告/停止に届くかを見る
#  naptime / log_autovacuum_min_duration は PG18 の既定値に戻す (この実験では既定値が結果を左右するため)
source /vagrant/scripts/common.sh
P=5510; N=e9; NT=20000
new_cluster $N $P "autovacuum_naptime = 60s" "log_autovacuum_min_duration = 10min" "max_locks_per_transaction = 256"
q $P postgres "CREATE EXTENSION xid_wraparound"
say "create $NT small tables (1 row each, 500 tables per transaction)"
T0=$(now)
for b in $(seq 0 $(( NT/500 - 1 ))); do
  qa $P postgres "DO \$\$ BEGIN FOR i IN $((b*500+1))..$((b*500+500)) LOOP EXECUTE format('CREATE TABLE tn_%s(id int primary key, v text); INSERT INTO tn_%s VALUES (1, ''x'')', i, i); END LOOP; END \$\$" >/dev/null
done
echo "created in $(since $T0) s"
q $P postgres "SELECT count(*) AS tables FROM pg_class WHERE relname LIKE 'tn\_%' AND relkind='r'"
q $P postgres "SELECT relname, pg_size_pretty(pg_total_relation_size(oid)) FROM pg_class WHERE relname IN ('pg_class','pg_attribute','pg_type','pg_depend') ORDER BY 1"
q $P postgres "VACUUM (FREEZE)" >/dev/null   # 開始点を揃える (全表 age≒0)
due(){ qa $P postgres "SELECT count(*) FROM pg_class WHERE relkind IN ('r','t','m') AND age(relfrozenxid) > 200000000"; }
can_write(){ test "$(qs $P postgres "SELECT pg_current_xact_id()")" = OK; }
workers(){ qa $P postgres "SELECT count(*) FROM pg_stat_activity WHERE backend_type='autovacuum worker'"; }

throughput(){ # <tag> : 210M 消費して全表を「期限超過」にし、消化されるまでを 5 秒毎に記録
  consume $P 210
  local d0=$(due); echo "due tables after +210M: $d0"
  echo "tp,$1,elapsed_s,due_tables,workers"
  local t0=$(now) el
  for i in $(seq 1 720); do
    local d=$(due); echo "tp,$1,$(since $t0),$d,$(workers)"
    [ "$d" -eq 0 ] && break
    sleep 5
  done
  el=$(since $t0)
  echo "all $d0 due tables processed in $el s -> $(echo "$d0 / $el" | bc) tables/s"
  eval "DRAIN_$1=${el%.*}"; metric "due_tables_$1" $d0; metric "drain_s_$1" $el; metric "tables_per_s_$1" $(echo "$d0 / $el" | bc)
}
say "A1: throughput with autovacuum_max_workers = 3 (default)"
throughput w3
say "A2: throughput with autovacuum_max_workers = 6 (PG18: reloadable up to autovacuum_worker_slots)"
q $P postgres "ALTER SYSTEM SET autovacuum_max_workers = 6"; qa $P postgres "SELECT pg_reload_conf()" >/dev/null; sleep 1
q $P postgres "SHOW autovacuum_max_workers"; q $P postgres "SHOW autovacuum_worker_slots"
throughput w6
check more_workers_drain_faster test "$DRAIN_w6" -lt "$DRAIN_w3"

say "B: race: consume at full speed (workers=3) and watch max age / due tables"
q $P postgres "ALTER SYSTEM RESET autovacuum_max_workers"; qa $P postgres "SELECT pg_reload_conf()" >/dev/null
echo "race,elapsed_s,consumed_M,max_age,due_tables,workers,msg"
T0=$(now); STOPPED=0
for i in $(seq 1 250); do
  out=$(psql -X -At -p $P -d postgres -c "SELECT consume_xids(10000000)" 2>&1)
  # 停止した回は WARNING の後に ERROR が来るので、ERROR を優先して記録する
  msg=$( { echo "$out" | grep -E '^ERROR'; echo "$out" | grep -E '^WARNING'; } | head -1 | cut -c1-70)
  [ $((i % 5)) -eq 0 ] || [ -n "$msg" ] && echo "race,$(since $T0),$((i*10)),$(maxage $P),$(due),$(workers),$msg"
  echo "$out" | grep -q '^ERROR' && { STOPPED=1; break; }
done | tee /tmp/e9.race
RMAX=$(awk -F, '{if($4>m)m=$4}END{print m}' /tmp/e9.race)
metric race_max_age $RMAX
metric race_elapsed_s $(tail -1 /tmp/e9.race | cut -d, -f2)
metric race_consumed_M $(tail -1 /tmp/e9.race | cut -d, -f3)
metric race_warned $(grep -c 'must be vacuumed' /tmp/e9.race)
metric race_stopped $(grep -c 'not accepting commands' /tmp/e9.race)
metric race_due_left_at_end $(tail -1 /tmp/e9.race | cut -d, -f5)
check race_reaches_stop_without_any_blocker test "$(grep -c 'not accepting commands' /tmp/e9.race)" -ge 1
if grep -q 'not accepting' /tmp/e9.race; then
  say "B': STOP reached with NO blocker. How long until autovacuum catches up?"
  W=$(wait_until 1800 can_write)
  metric race_stop_duration_s $W; echo "writes resumed after $W s"
fi
state $P
diag $P | head -12
check no_blocker_in_diag test "$(qa $P postgres "SELECT count(*) FROM pg_stat_activity WHERE backend_type='client backend' AND pid<>pg_backend_pid() AND backend_xmin IS NOT NULL")" -eq 0
log_audit $N
finish
