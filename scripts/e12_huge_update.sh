#!/bin/bash
# E12: 巨大テーブルへの大量更新と、その後の周回防止 VACUUM のコスト
#  凍結済み (all-frozen) の 8M 行 / 1.3GB 表を 4 つ用意し:
#    ua: 何もしない (静的)          ub: 1% の行を全体にばらけて更新 (日次の少量更新)
#    uc / ud: 全行 UPDATE (一括移行・列追加の埋め戻し)。UPDATE 自体の実行中は XID を持つロングトランザクションになる
#  (1) age < 2 億のうちに手動の aggressive VACUUM (コスト遅延なし) で ua / ub / ud を測る (ud は maintenance_work_mem=8MB: 既定 64MB では 1 パスで済んだ)
#  (2) uc は 2 億を越えさせ、本物の周回防止 autovacuum (既定のコスト遅延) に処理させてサーバログから測る
#  ※ 初回実行では手動 VACUUM の前に 2 億を越えてしまい、手動 VACUUM が周回防止ワーカーのロック待ちで 6 分以上止まった
source /vagrant/scripts/common.sh
P=5513; N=e12
new_cluster $N $P "autovacuum = off" "track_io_timing = on" "checkpoint_timeout = 1h"
for e in xid_wraparound pg_visibility; do q $P postgres "CREATE EXTENSION $e" >/dev/null; done
frozen_pct(){ qa $P postgres "SELECT round(100.0*(pg_visibility_map_summary('$1')).all_frozen/greatest(pg_relation_size('$1')/8192,1),1)"; }
mk(){ q $P postgres "CREATE TABLE $1(id int primary key, v int, pad text); INSERT INTO $1 SELECT g, 0, repeat('u',120) FROM generate_series(1,8000000) g;" | tail -1; q $P postgres "VACUUM (FREEZE, ANALYZE) $1"; }
for t in ua ub uc ud; do mk $t; done
q $P postgres "SELECT relname, pg_size_pretty(pg_relation_size(oid)) heap, pg_relation_size(oid)/8192 AS pages FROM pg_class WHERE relname IN ('ua','ub','uc','ud') ORDER BY 1"
metric rows_per_page $(qa $P postgres "SELECT round(8000000.0 / (pg_relation_size('ua')/8192), 1)")

say "B: 1% scattered update (80k rows, random ids) on ub"
q $P postgres "UPDATE ub SET v = v + 1 WHERE id IN (SELECT (random()*7999999)::int + 1 FROM generate_series(1,80000))"
say "C: full-table UPDATE on uc and ud; while it runs it is a long transaction holding an XID"
( s=$(now); qa $P postgres "UPDATE uc SET v = v + 1" >/dev/null; echo "UPDATE uc took $(since $s) s" > /tmp/e12_upd.txt ) &
UJ=$!; sleep 3
consume $P 20
q $P postgres "SELECT state, backend_xid, age(backend_xid) AS xid_age, now()-xact_start AS running_for, left(query,30) AS query FROM pg_stat_activity WHERE query LIKE 'UPDATE uc%'"
echo "--- VACUUM of an unrelated table while the UPDATE runs: its cutoff is pinned at the UPDATE's XID"
q $P postgres "VACUUM (VERBOSE) ua" 2>&1 | grep -E 'removable cutoff'
wait $UJ; cat /tmp/e12_upd.txt
metric full_update_s $(grep -oE '[0-9.]+ s' /tmp/e12_upd.txt | cut -d' ' -f1)
q $P postgres "UPDATE ud SET v = v + 1" | tail -1
q $P postgres "CHECKPOINT" >/dev/null
echo "rel | all-frozen % | heap after"
for t in ua ub uc ud; do echo "$t | $(frozen_pct $t) | $(qa $P postgres "SELECT pg_size_pretty(pg_relation_size('$t'))")"; metric frozen_pct_before_$t $(frozen_pct $t); done
# 1 ページ約 49 行: 1% をランダムに更新したとき、あるページが一度も触られない確率は 0.99^49 ≈ 61%
check scattered_1pct_update_matches_theory_61pct test "$(frozen_pct ub | cut -d. -f1)" -ge 55 -a "$(frozen_pct ub | cut -d. -f1)" -le 67

say "(1) consume 140M (age ~160M: > vacuum_freeze_table_age, < autovacuum_freeze_max_age) -> manual aggressive VACUUM, no cost delay"
consume $P 140
state $P
check still_below_antiwrap_threshold test "$(maxage $P)" -lt 190000000
echo "agg,rel,mwm,scanned_pages,total_pages,index_scans,wall_s,wal_mb,fpi"
agg(){ # <rel> <maintenance_work_mem> : 対象表自身の "finished vacuuming" ブロックだけを解析する
  local s=$(now)
  local out=$(PGOPTIONS="-c maintenance_work_mem=$2" psql -X -p $P -d postgres -c "VACUUM (VERBOSE) $1" 2>&1 | sed -n "/finished vacuuming \"postgres.public.$1\"/,/system usage/p")
  local w=$(since $s)
  echo "$out" | sed 's/^/  | /'
  local sc=$(echo "$out" | grep -oE '[0-9]+ scanned' | head -1 | cut -d' ' -f1)
  local tot=$(echo "$out" | grep -oE '[0-9]+ remain' | head -1 | cut -d' ' -f1)
  local ix=$(echo "$out" | grep -oE 'index scans: [0-9]+' | head -1 | awk '{print $3}')
  local wal=$(echo "$out" | grep -oE '[0-9]+ bytes' | head -1 | awk '{print int($1/1048576)}')
  local fpi=$(echo "$out" | grep -oE '[0-9]+ full page images' | head -1 | cut -d' ' -f1)
  echo "agg,$1,$2,$sc,$tot,$ix,$w,$wal,$fpi"
  metric "agg_${1}_scanned" $sc; metric "agg_${1}_total" $tot; metric "agg_${1}_index_scans" $ix; metric "agg_${1}_wall_s" $w; metric "agg_${1}_wal_mb" $wal
}
{ agg ua 64MB; agg ub 64MB; agg ud 8MB; } | tee /tmp/e12.agg
col(){ awk -F, -v r=$1 -v c=$2 '$1=="agg" && $2==r{print $c}' /tmp/e12.agg; }
check static_table_scans_almost_nothing test "$(col ua 4)" -lt 100
# 61% が all-frozen でも、連続 32 ページ (SKIP_PAGES_THRESHOLD) 未満の区間は読み飛ばさないので、ほぼ全ページを読む
check scattered_update_scans_almost_all_pages test "$(col ub 4)" -ge $(( $(col ub 5) * 95 / 100 ))
# PG17+ の TID ストアは省メモリ: 8MB でも 800 万 dead tuple を 1 周で処理できる
check tid_store_8mb_single_index_pass test "$(col ud 6)" -eq 1

say "(1b) where maintenance_work_mem still matters: 200k-row table, full UPDATE, 64kB vs 64MB"
ix_scans(){ PGOPTIONS="-c maintenance_work_mem=$2" psql -X -p $P -d postgres -c "VACUUM (VERBOSE) $1" 2>&1 | grep -m1 -oE "finished vacuuming \"postgres.public.$1\": index scans: [0-9]+" | awk '{print $NF}'; }
for t in sm1 sm2; do q $P postgres "CREATE TABLE $t(id int primary key, v int, pad text); INSERT INTO $t SELECT g, 0, repeat('s',120) FROM generate_series(1,200000) g;" | tail -1; q $P postgres "UPDATE $t SET v = 1" | tail -1; done
S64K=$(ix_scans sm1 64kB); S64M=$(ix_scans sm2 64MB)
echo "index scans: 64kB=$S64K 64MB=$S64M"
metric small_mwm_index_scans_64kb $S64K; metric small_mwm_index_scans_64mb $S64M
check tiny_mwm_needs_many_index_passes test "$S64K" -gt 10 -a "$S64M" -eq 1

say "(2) push age past 200M and let the real anti-wraparound autovacuum (default cost delay) process uc"
logmark $N
consume $P 50
uc_done(){ logsince $N | grep -q 'wraparound of table "postgres.public.uc"'; }
W=$(wait_until 2400 uc_done); echo "anti-wraparound autovacuum of uc finished $W s after the threshold was crossed"
logsince $N | grep -A16 'wraparound of table "postgres.public.uc"' | tee /tmp/e12_av.log | sed 's/^/  | /'
metric av_uc_elapsed_s $(grep -oE 'elapsed: [0-9.]+' /tmp/e12_av.log | awk '{print $2}')
metric av_uc_read_mbps $(grep -oE 'avg read rate: [0-9.]+' /tmp/e12_av.log | awk '{print $4}')
metric av_uc_wal_mb $(grep -oE '[0-9]+ bytes' /tmp/e12_av.log | head -1 | awk '{print int($1/1048576)}')
metric av_uc_fpi $(grep -oE '[0-9]+ full page images' /tmp/e12_av.log | head -1 | cut -d' ' -f1)
metric av_uc_pages $(grep -oE '[0-9]+ scanned' /tmp/e12_av.log | head -1 | cut -d' ' -f1)
check antiwrap_autovacuum_processed_uc test "$W" != -1
log_audit $N
finish
