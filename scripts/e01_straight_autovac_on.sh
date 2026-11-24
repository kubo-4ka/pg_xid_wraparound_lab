#!/bin/bash
# E1: 既定設定(autovacuum on)で 25億 XID を高速消費 -> 周回防止autovacuumが追いつくか
#  age は 10M チャンクごと (= 毎トランザクション) に採取する (最大値を観測点間で取りこぼさないため)
source /vagrant/scripts/common.sh
P=5501; N=e1
new_cluster $N $P
q $P postgres "CREATE EXTENSION xid_wraparound"
q $P postgres "CREATE TABLE t(id int, pad text); INSERT INTO t SELECT g, repeat('x',100) FROM generate_series(1,2000000) g; CREATE INDEX ON t(id);"
q $P postgres "SELECT pg_size_pretty(pg_total_relation_size('t'))"
logmark $N
say "consume 2.5B XIDs in 10M chunks (1 chunk = 1 transaction)"
echo "csv,elapsed_s,consumed_M,max_age_datfrozenxid,age_t,av_workers,warn"
T0=$(now)
for i in $(seq 1 250); do
  out=$(psql -X -At -p $P -d postgres -c "SELECT consume_xids(10000000)" 2>&1)
  w=$(echo "$out" | grep -c WARNING)
  r=$(qa $P postgres "SELECT (SELECT max(age(datfrozenxid)) FROM pg_database)||','||age(relfrozenxid)||','||(SELECT count(*) FROM pg_stat_activity WHERE backend_type='autovacuum worker') FROM pg_class WHERE relname='t'")
  echo "csv,$(since $T0),$((i*10)),$r,$w"
  echo "$out" | grep -E 'WARNING|ERROR' | head -2
done | tee /tmp/e1.csv
EL=$(tail -1 /tmp/e1.csv | cut -d, -f2)
MAXAGE=$(awk -F, '/^csv,[0-9]/{if($4>m)m=$4}END{print m}' /tmp/e1.csv)
WARNS=$(awk -F, '/^csv,[0-9]/{s+=$7}END{print s+0}' /tmp/e1.csv)
metric elapsed_s $EL
metric xid_per_s $(echo "2500000000 / $EL" | bc)
metric max_age $MAXAGE
metric warn_chunks $WARNS
metric final_max_age $(maxage $P)
state $P
check no_warning_reached test "$WARNS" -eq 0
check max_age_below_failsafe test "$MAXAGE" -lt 1600000000
check final_age_below_400M test "$(maxage $P)" -lt 400000000
check wrapped_past_2pow31 test "$(qa $P postgres "SELECT (pg_current_xact_id()::text::bigint > 2147483648)::int")" = 1
say "autovacuum log summary"
AW=$(logsince $N | grep -c 'to prevent wraparound')
metric antiwrap_log_lines $AW
echo "anti-wraparound autovacuum log lines: $AW"
logsince $N | grep -E 'automatic (aggressive )?vacuum' | awk '{print $6,$7,$8,$9,$10,$11,$12,$13}' | sort | uniq -c | head -20
logsince $N | grep -A3 'aggressive vacuum to prevent wraparound of table "postgres.public.t"' | head -12
metric t_pages_scanned_last "$(logsince $N | grep -A1 'wraparound of table "postgres.public.t"' | grep -oE '[0-9]+ scanned' | tail -1 | cut -d' ' -f1)"
metric t_pages_total "$(logsince $N | grep -A1 'wraparound of table "postgres.public.t"' | grep -oE '[0-9]+ remain' | tail -1 | cut -d' ' -f1)"
log_audit $N
finish
