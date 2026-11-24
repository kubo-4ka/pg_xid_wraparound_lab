#!/bin/bash
# E15: 可視性境界の直接観測 (QA F-04 / #2)
#  xmin=X の行が、スナップショットの xmax (= 次 XID) が X+2^31 / X+2^32 の前後 1 XID でどう見えるかを、
#  シングルユーザーモードで 1 XID ずつ進めて観測する。xmin を 3 つずらした表 w1..w3 を置き、クラスタを作り直して 3 回反復。
#  d = snapshot xmax - xmin として、理論 (TransactionIdFollowsOrEquals の 32bit 循環比較) では
#    d <= 2^31      : 見える     d = 2^31+1 .. 2^32 : 見えない     d >= 2^32+1 : 再び見える
source /vagrant/scripts/common.sh
P=5516
single(){ printf '%s\n' "$@" | postgres --single -D $D -c autovacuum=off -c log_min_messages=error lab 2>&1; }
probe_sql="SELECT 'PROBE,'||(pg_snapshot_xmax(pg_current_snapshot())::text::bigint - (SELECT x FROM meta))||','||(SELECT count(*) FROM w1)||','||(SELECT count(*) FROM w2)||','||(SELECT count(*) FROM w3) AS r"
steps(){ # <target offset from X1> : そこまで一気に進め、以後 1 XID ずつ 16 回 probe
  local stmts=("SELECT consume_xids_until(((SELECT x FROM meta) + $1)::text::xid8)" "SELECT pg_current_xact_id()")
  for i in $(seq 1 16); do stmts+=("$probe_sql" "SELECT pg_current_xact_id()"); done
  single "${stmts[@]}" | grep -oE 'PROBE,[-0-9,]+'
}
echo "csv15,rep,d_from_w1,w1,w2,w3"
for rep in 1 2 3; do
  N=e15_$rep; D=$LAB/$N
  new_cluster $N $P "autovacuum = off"
  q $P postgres "CREATE DATABASE lab" >/dev/null
  q $P lab "CREATE EXTENSION xid_wraparound" >/dev/null
  q $P lab "CREATE TABLE meta(x bigint); CREATE TABLE w1(i int); CREATE TABLE w2(i int); CREATE TABLE w3(i int);" >/dev/null
  # w1, w2, w3 を別トランザクションで挿入 (xmin が 2 ずつずれるよう間に 1 XID 挟む)
  q $P lab "INSERT INTO w1 SELECT generate_series(1,100)" >/dev/null; qa $P lab "SELECT pg_current_xact_id()" >/dev/null
  q $P lab "INSERT INTO w2 SELECT generate_series(1,100)" >/dev/null; qa $P lab "SELECT pg_current_xact_id()" >/dev/null
  q $P lab "INSERT INTO w3 SELECT generate_series(1,100)" >/dev/null
  q $P lab "INSERT INTO meta SELECT xmin::text::bigint FROM w1 LIMIT 1" >/dev/null
  q $P lab "SELECT (SELECT min(xmin::text::bigint) FROM w1) w1_xmin, (SELECT min(xmin::text::bigint) FROM w2) w2_xmin, (SELECT min(xmin::text::bigint) FROM w3) w3_xmin, (SELECT count(*) FROM w1)+(SELECT count(*) FROM w2)+(SELECT count(*) FROM w3) AS all_rows_hinted"
  # w1..w3 以外 (カタログ, meta) を凍結し、他 DB も凍結。w1..w3 は VACUUM しない (all-visible にしない)
  psql -X -At -p $P -d lab -c "SELECT format('VACUUM (FREEZE) %s;', oid::regclass) FROM pg_class WHERE relkind IN ('r','m','t') AND relname NOT IN ('w1','w2','w3')" | psql -X -q -p $P -d lab
  for db in postgres template1; do vacuumdb -q -p $P --freeze -d $db; done
  q $P lab "CHECKPOINT" >/dev/null
  stop $N
  steps $((2**31 - 6))  | sed "s/^PROBE/csv15,$rep/"
  steps $((2**32 - 6))  | sed "s/^PROBE/csv15,$rep/"
  drop_cluster $N
done | tee /tmp/e15.csv
# 判定: 各表 k (xmin = X1 + 2(k-1)) について d_k = d - 2(k-1)
viol=$(awk -F, '$1=="csv15" && $2~/^[0-9]+$/{
  for(k=1;k<=3;k++){ d=$3-2*(k-1); v=$(3+k);
    if (d<=2147483648) ex=100; else if (d<=4294967296) ex=0; else ex=100;
    n++; if (v!=ex) {bad++; print "VIOLATION rep="$2" table=w"k" d="d" visible="v" expected="ex > "/dev/stderr"} } }
  END{print bad+0 "/" n}' /tmp/e15.csv)
echo "violations/observations: $viol"
metric observations ${viol#*/}
metric violations ${viol%/*}
check boundary_matches_theory_exactly test "${viol%/*}" -eq 0
# 境界の直近で観測できていること (d = 2^31, 2^31+1, 2^32, 2^32+1 がすべて含まれる)
for b in 2147483648 2147483649 4294967296 4294967297; do
  check "observed_d_$b" test "$(awk -F, -v b=$b '$1=="csv15" && ($3==b || $3-2==b || $3-4==b)' /tmp/e15.csv | wc -l)" -ge 3
done
finish
