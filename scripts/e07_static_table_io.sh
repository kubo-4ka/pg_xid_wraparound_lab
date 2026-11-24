#!/bin/bash
# E7: 「XID周回に潜む別の問題」= 静的テーブルの周回防止VACUUMのI/O (all-frozen VM の効果)
#  Part1 因子分離 (QA #4): ロード直後の通常 VACUUM で all-frozen になるかを決める要因
#        checksums on/off, wal_log_hints, ロード後 VACUUM 前の CHECKPOINT 有無 (各 4M 行; ページ数は決定的なので 1 回)
#  Part2 --no-data-checksums: A=通常VACUUMのみ(all-visible) / B=VACUUM FREEZE を各 3 表ずつ用意し、
#        160M XID 消費後の aggressive VACUUM をコールドキャッシュで 3 回ずつ比較
#  Part3 PG18 eager scanning: 非aggressive VACUUM の繰り返しで all-frozen が増えるか
source /vagrant/scripts/common.sh
P=5508
vm(){ q $P postgres "SELECT '$1' AS rel, (pg_visibility_map_summary('$1')).*, (SELECT relpages FROM pg_class WHERE relname='$1') AS relpages, age(relfrozenxid) FROM pg_class WHERE relname='$1'" | sed -n 3p; }
frozen_pct(){ qa $P postgres "SELECT round(100.0*(pg_visibility_map_summary('$1')).all_frozen/greatest(relpages,1),1) FROM pg_class WHERE relname='$1'"; }
load(){ q $P postgres "CREATE TABLE $1(id bigint, pad text); INSERT INTO $1 SELECT g, repeat('z',120) FROM generate_series(1,${2:-8000000}) g;" | tail -1; }
vv(){ q $P postgres "VACUUM (VERBOSE $2) $1" 2>&1 | sed -n "/public.$1/,/system usage/p" | grep -E 'vacuuming|pages:|frozen:|visibility map|read rate|buffer usage|WAL usage|system usage'; }
cold(){ stop $N; sync; echo 3 | sudo -n /usr/bin/tee /proc/sys/vm/drop_caches >/dev/null; start $N; }
COMMON=("autovacuum = off" "track_io_timing = on" "checkpoint_timeout = 1h")

say "Part1: which factor makes the first plain VACUUM after a bulk load freeze everything?"
echo "factor,cluster,checksums,wal_log_hints,checkpoint_before_vacuum,frozen_pct,vacuum_wal"
f(){ # <tag> <checkpoint yes/no>
  load $1 4000000 >/dev/null
  [ "$2" = yes ] && q $P postgres "CHECKPOINT" >/dev/null
  local out=$(vv $1); local wal=$(echo "$out" | grep -oE 'WAL usage: [^,]+, [^,]+, [0-9]+ bytes' | grep -oE '[0-9]+ bytes')
  echo "factor,$N,$(qa $P postgres "SHOW data_checksums"),$(qa $P postgres "SHOW wal_log_hints"),$2,$(frozen_pct $1),$wal"
  metric frozen_pct_$1 $(frozen_pct $1)
}
N=e7a; INITDB_OPTS="" new_cluster $N $P "${COMMON[@]}"
q $P postgres "CREATE EXTENSION pg_visibility" >/dev/null
f ck_on_cp_yes yes; f ck_on_cp_no no
check checksums_on_with_checkpoint_freezes_all test "$(frozen_pct ck_on_cp_yes | cut -d. -f1)" -ge 99
log_audit $N; drop_cluster $N
N=e7b; INITDB_OPTS="--no-data-checksums" new_cluster $N $P "${COMMON[@]}" "wal_log_hints = on"
q $P postgres "CREATE EXTENSION pg_visibility" >/dev/null
f hints_on_cp_yes yes
log_audit $N; drop_cluster $N

say "Part2: --no-data-checksums, 3 x (A plain VACUUM, B VACUUM FREEZE), aggressive VACUUM on cold cache"
N=e7; INITDB_OPTS="--no-data-checksums" new_cluster $N $P "${COMMON[@]}" "autovacuum_freeze_max_age = 1000000000"
q $P postgres "SHOW data_checksums"
for e in xid_wraparound pg_visibility; do q $P postgres "CREATE EXTENSION $e" >/dev/null; done
f ck_off_cp_yes yes
check checksums_off_plain_vacuum_does_not_freeze test "$(frozen_pct ck_off_cp_yes | cut -d. -f1)" -le 1
q $P postgres "DROP TABLE ck_off_cp_yes" >/dev/null
for r in 1 2 3; do load sa$r; load sb$r; done
q $P postgres "CHECKPOINT" >/dev/null
for r in 1 2 3; do echo "--- sa$r: plain VACUUM"; vv sa$r | grep -E 'pages:|frozen:|WAL usage'; echo "--- sb$r: VACUUM FREEZE"; vv sb$r ", FREEZE" | grep -E 'pages:|frozen:|WAL usage'; done
load sc; q $P postgres "VACUUM sc" >/dev/null
echo "rel | all_visible | all_frozen | relpages | age"; for t in sa1 sb1 sc; do vm $t; done
say "consume 160M XIDs (> vacuum_freeze_table_age=150M -> next VACUUM is aggressive)"
consume $P 160
echo "csv7,cond,rep,scanned_pages,total_pages,wall_s,read_blocks,wal_bytes"
for r in 1 2 3; do for c in a b; do
  t=s$c$r
  cold; s=$(now)
  out=$(vv $t); w=$(since $s)
  sc=$(echo "$out" | grep -oE '[0-9]+ scanned' | head -1 | cut -d' ' -f1)
  tot=$(echo "$out" | grep -oE '[0-9]+ remain' | head -1 | cut -d' ' -f1)
  rd=$(echo "$out" | grep -oE '[0-9]+ reads' | head -1 | cut -d' ' -f1)
  wal=$(echo "$out" | grep -oE '[0-9]+ bytes' | head -1 | cut -d' ' -f1)
  echo "csv7,$c,$r,$sc,$tot,$w,$rd,$wal"
done; done | tee /tmp/e7.csv
for c in a b; do
  metric agg_wall_s_${c}_median $(awk -F, -v c=$c '$2==c{print $6}' /tmp/e7.csv | sort -n | sed -n 2p)
  metric agg_wall_s_${c}_min $(awk -F, -v c=$c '$2==c{print $6}' /tmp/e7.csv | sort -n | head -1)
  metric agg_wall_s_${c}_max $(awk -F, -v c=$c '$2==c{print $6}' /tmp/e7.csv | sort -n | tail -1)
  metric agg_scanned_${c}_max $(awk -F, -v c=$c '$2==c{print $4}' /tmp/e7.csv | sort -n | tail -1)
  metric agg_wal_mb_${c}_median $(awk -F, -v c=$c '$2==c{print int($8/1048576)}' /tmp/e7.csv | sort -n | sed -n 2p)
done
metric total_pages $(awk -F, '$2=="a"{print $5}' /tmp/e7.csv | head -1)
check a_scans_all_pages test "$(awk -F, '$2=="a" && $4<$5*0.99' /tmp/e7.csv | wc -l)" -eq 0
check b_scans_almost_nothing test "$(awk -F, '$2=="b" && $4>10' /tmp/e7.csv | wc -l)" -eq 0

say "Part3: PG18 eager scanning on sc (all-visible, not frozen), non-aggressive VACUUM every +60M XIDs"
q $P postgres "SHOW vacuum_max_eager_freeze_failure_rate"
echo "round | rel | all_visible | all_frozen | relpages | age"
for r in 1 2 3 4 5 6; do
  consume $P 60
  printf "SET vacuum_freeze_table_age = 900000000;\nVACUUM (VERBOSE) sc;\n" | psql -X -p $P -d postgres 2>&1 | sed -n '/public.sc/,/visibility map/p' | grep -E 'vacuuming|pages:|frozen:'
  echo "round $r | $(vm sc)"
done
metric eager_frozen_pct_after_6 $(frozen_pct sc)
check eager_scanning_freezes_over_half test "$(frozen_pct sc | cut -d. -f1)" -ge 50
log_audit $N
finish
