#!/bin/bash
# E8: 実運用の速度感 — どの操作が何個の XID を消費するか / この VM で現実的なワークロードは何 XID/s か (QA #5)
#  XID 消費量は pg_snapshot_xmax(pg_current_snapshot()) の差分で測る (この関数自体は XID を消費しない)
#  autovacuum=off (ANALYZE による XID 消費を混ぜないため)
source /vagrant/scripts/common.sh
P=5509; N=e8
new_cluster $N $P "autovacuum = off" "max_connections = 100"
nx(){ qa $P postgres "SELECT pg_snapshot_xmax(pg_current_snapshot())::text"; }
pgbench -i -q -s 20 -p $P postgres 2>&1 | tail -1
q $P postgres "CREATE TABLE ev(id bigserial primary key, v int); CREATE SEQUENCE s; CREATE TABLE uq(id int primary key);"
q $P postgres "INSERT INTO uq SELECT g FROM generate_series(1,100000) g"

say "A: per-operation XID cost (1 statement or 1 transaction each, measured by xmax delta)"
echo "op,xids_consumed,units,xids_per_unit"
op(){ # <label> <units> <sql>
  local a=$(nx); psql -X -q -p $P -d postgres -c "$3" >/dev/null 2>&1; local b=$(nx)
  local d=$((b-a)); echo "op,$1,$d,$2,$(echo "scale=3; $d/$2" | bc)"
  metric "xids_per_$1" $(echo "scale=3; $d/$2" | bc)
}
op select_only 1 "SELECT count(*) FROM pgbench_accounts WHERE aid < 1000"
op read_only_explicit_tx 1 "BEGIN; SELECT 1; SELECT 2; COMMIT;"
op insert_1row 1 "INSERT INTO ev(v) VALUES (1)"
op insert_1000rows_1tx 1000 "INSERT INTO ev(v) SELECT g FROM generate_series(1,1000) g"
op select_for_update_1tx 1 "BEGIN; SELECT * FROM pgbench_accounts WHERE aid=1 FOR UPDATE; COMMIT;"
op select_for_share_1tx 1 "BEGIN; SELECT * FROM pgbench_accounts WHERE aid=2 FOR SHARE; COMMIT;"
op nextval_x3200 3200 "SELECT nextval('s') FROM generate_series(1,3200)"
op create_temp_table 1 "CREATE TEMP TABLE tt(i int)"
op savepoint_per_stmt_10 10 "BEGIN; SAVEPOINT a; INSERT INTO ev(v) VALUES (1); RELEASE a; SAVEPOINT a; INSERT INTO ev(v) VALUES (1); RELEASE a; SAVEPOINT a; INSERT INTO ev(v) VALUES (1); RELEASE a; SAVEPOINT a; INSERT INTO ev(v) VALUES (1); RELEASE a; SAVEPOINT a; INSERT INTO ev(v) VALUES (1); RELEASE a; SAVEPOINT a; INSERT INTO ev(v) VALUES (1); RELEASE a; SAVEPOINT a; INSERT INTO ev(v) VALUES (1); RELEASE a; SAVEPOINT a; INSERT INTO ev(v) VALUES (1); RELEASE a; SAVEPOINT a; INSERT INTO ev(v) VALUES (1); RELEASE a; SAVEPOINT a; INSERT INTO ev(v) VALUES (1); RELEASE a; COMMIT;"
op plpgsql_exception_loop_100k 100000 "DO \$\$ BEGIN FOR i IN 1..100000 LOOP BEGIN INSERT INTO ev(v) VALUES (i); EXCEPTION WHEN others THEN NULL; END; END LOOP; END \$\$"
op plpgsql_exception_loop_readonly_100k 100000 "DO \$\$ DECLARE x int; BEGIN FOR i IN 1..100000 LOOP BEGIN SELECT 1 INTO x; EXCEPTION WHEN others THEN NULL; END; END LOOP; END \$\$"
op upsert_conflict_do_nothing_100k 100000 "INSERT INTO uq SELECT g FROM generate_series(1,100000) g ON CONFLICT DO NOTHING"
A=$(nx); qa $P postgres "SELECT count(*) FROM pgbench_accounts" >/dev/null; B=$(nx)
check select_consumes_zero_xids test "$((B-A))" -eq 0
A=$(nx); psql -X -q -p $P -d postgres -c "DO \$\$ BEGIN FOR i IN 1..10000 LOOP BEGIN INSERT INTO ev(v) VALUES (i); EXCEPTION WHEN others THEN NULL; END; END LOOP; END \$\$" >/dev/null; B=$(nx)
check exception_block_burns_one_xid_per_iteration test "$((B-A))" -ge 10000
A=$(nx); for i in $(seq 1 320); do psql -X -q -p $P -d postgres -c "SELECT nextval('s')" >/dev/null; done; B=$(nx)
echo "320 autocommit nextval() calls consumed $((B-A)) XIDs"
metric xids_per_nextval_autocommit $(echo "scale=3; $((B-A))/320" | bc)
check nextval_autocommit_assigns_xid_every_32_calls test "$((B-A))" -ge 9 -a "$((B-A))" -le 11

say "B: sustained workloads with pgbench (8 clients, 30 s each) -> XID/s on this VM"
echo "wl,workload,tps,xids,xid_per_s"
wl(){ # <label> <pgbench args...>
  local l=$1; shift
  local a=$(nx); local out=$(pgbench -p $P -c 8 -j 4 -T 30 -n "$@" postgres 2>&1); local b=$(nx)
  local tps=$(echo "$out" | grep -oE 'tps = [0-9.]+' | head -1 | awk '{print int($3)}')
  echo "wl,$l,$tps,$((b-a)),$(( (b-a)/30 ))"
  metric "wl_${l}_tps" $tps; metric "wl_${l}_xid_per_s" $(( (b-a)/30 ))
}
wl select_only -S
wl tpcb_like
PGOPTIONS="-c synchronous_commit=off" wl tpcb_like_async
printf "SET synchronous_commit=off;\nBEGIN;\n\\\\set a random(1,2000000)\nSELECT * FROM pgbench_accounts WHERE aid=:a FOR UPDATE;\nCOMMIT;\n" > /tmp/e8_sfu.sql
wl select_for_update_async -f /tmp/e8_sfu.sql
printf "\\\\set a random(1,2000000)\nSELECT nextval('s');\n" > /tmp/e8_nv.sql
wl nextval_only -f /tmp/e8_nv.sql

say "C: what the measured rates mean (time to reach each threshold at a constant rate)"
echo "rate_xid_per_s,to_200M_h,to_1.6B_d,to_2.1B_d"
for r in 100 1000 5000 10000 30000 100000; do
  echo "$r,$(echo "scale=1; 200000000/$r/3600" | bc),$(echo "scale=1; 1600000000/$r/86400" | bc),$(echo "scale=1; 2144483647/$r/86400" | bc)"
done
log_audit $N
finish
