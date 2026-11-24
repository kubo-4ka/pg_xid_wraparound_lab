#!/bin/bash
# E6: 可視性崩壊の実測
#  6-0 シングルユーザーモードで周回 -> 「データベースそのもの」が見えなくなる (未凍結のカタログ行)
#  6a  カタログを凍結済みの DB で、ユーザ表の行がバッチ単位で消える/再出現する様子を計測
#  6b  崩壊状態での SELECT / pg_dump / pageinspect / amcheck / VACUUM
#  6c  pg_resetwal -x の誤用による瞬間崩壊
source /vagrant/scripts/common.sh
single(){ # <datadir> <db> <sql...>
  local D=$1 db=$2; shift 2
  printf '%s\n' "$@" | postgres --single -D $D -c autovacuum=off -c log_min_messages=warning $db 2>&1 \
   | grep -vE '^\s*$|^PostgreSQL stand-alone|^backend>|----'
}
freeze_all_but(){ # <port> <db> <excluded table>
  psql -X -At -p $1 -d $2 -c "SELECT format('VACUUM (FREEZE) %s;', oid::regclass) FROM pg_class WHERE relkind IN ('r','m','t') AND relname <> '$3'" | psql -X -q -p $1 -d $2
}

say "6-0: default cluster, wrap in single-user mode: what happens to the database itself?"
P=5506; N=e60; D=$LAB/$N
new_cluster $N $P "autovacuum = off"
q $P postgres "CREATE EXTENSION xid_wraparound" >/dev/null
q $P postgres "CREATE TABLE w AS SELECT g FROM generate_series(1,1000) g"
q $P postgres "SELECT datname, datfrozenxid, xmin, (xmin::text::bigint < 3) AS frozen_or_bootstrap FROM pg_database ORDER BY 1"
stop $N
for i in 1 2 3 4 5 6 7 8 9; do single $D postgres "SELECT consume_xids(250000000)" | grep -E 'WARNING|FATAL|consume_xids =' | tail -1; done
start $N
echo "--- connect to postgres DB:"; q $P postgres "SELECT count(*) FROM w" | head -1
# 接続時の FATAL は psql が SQLSTATE を出さないので、メッセージで判定する
check e60_postgres_db_vanished test "$(q $P postgres "SELECT 1" | grep -c 'database "postgres" does not exist')" -ge 1
check e60_template1_vanished test "$(q $P template1 "SELECT 1" | grep -c 'database "template1" does not exist')" -ge 1
echo "--- connect to template1: list databases"; q $P template1 "SELECT datname, xmin FROM pg_database ORDER BY 1"
echo "--- psql -l"; psql -X -p $P -d template1 -l 2>&1 | head -8
echo "--- files still on disk:"; du -sh $D/base/* | head
log_audit $N 'does not exist'
drop_cluster $N

say "6a: catalogs frozen; only table w (4 batches) is unfrozen; f is a frozen control"
P=5506; N=e6; D=$LAB/$N
new_cluster $N $P "autovacuum = off"
q $P postgres "CREATE DATABASE lab" >/dev/null
for e in xid_wraparound pageinspect amcheck; do q $P lab "CREATE EXTENSION $e" >/dev/null; done
q $P lab "CREATE TABLE w(batch int, id int)" >/dev/null
q $P lab "CREATE TABLE f(id int)" >/dev/null
q $P lab "INSERT INTO w SELECT 0, g FROM generate_series(1,1000) g"
q $P lab "INSERT INTO f SELECT g FROM generate_series(1,1000) g"
freeze_all_but $P lab w
for db in postgres template1; do vacuumdb -q -p $P --freeze -d $db; done
q $P lab "SELECT relname, age(relfrozenxid) FROM pg_class WHERE relname IN ('w','f','pg_class','pg_database') ORDER BY 1"
stop $N
say "6a-1: insert batches 1..3 at +500M XIDs each (single-user mode)"
for k in 1 2 3; do
  single $D lab "SELECT consume_xids(500000000)" "INSERT INTO w SELECT $k, g FROM generate_series(1,1000) g" | grep -E 'ERROR|FATAL'
done
single $D lab "SELECT batch, min(xmin::text::bigint) AS xmin FROM w GROUP BY batch ORDER BY 1" | grep -E '= "'
say "6a-2: keep consuming in single-user mode, count visible rows per batch every 250M"
echo "csv,next_xid8,b0,b1,b2,b3,frozen_f,warn"
for s in $(seq 1 14); do
  out=$(single $D lab "SELECT consume_xids(250000000)" "SELECT pg_current_xact_id() AS advance_latest_completed" \
    "SELECT 'CNT', (SELECT count(*) FROM w WHERE batch=0) AS b0, (SELECT count(*) FROM w WHERE batch=1) AS b1, (SELECT count(*) FROM w WHERE batch=2) AS b2, (SELECT count(*) FROM w WHERE batch=3) AS b3, (SELECT count(*) FROM f) AS f, pg_current_xact_id()::text AS nx")
  c=$(echo "$out" | grep -A7 '"CNT"' | grep -oE '= "[0-9]+"' | tr -dc '0-9\n' | paste -sd,)
  nx=${c##*,}; c=${c%,*}
  w=$(echo "$out" | grep -m1 -oE 'must be vacuumed within [0-9]+' || echo "-")
  e=$(echo "$out" | grep -m1 -E 'ERROR|FATAL|PANIC')
  echo "csv,$nx,$c,$w $e"
  if [ $s -eq 3 ]; then
    say "6b: multi-user look at the collapsed state (batch0 should be gone)"
    start $N
    q $P lab "SELECT batch, count(*) FROM w GROUP BY batch ORDER BY 1"
    check e6b_visible_rows_3000 test "$(qa $P lab "SELECT count(*) FROM w")" -eq 3000
    echo "--- physically present tuples (pageinspect):"
    q $P lab "SELECT count(*) AS raw_tuples, count(*) FILTER (WHERE t_xmin::text::bigint < 100000) AS raw_batch0 FROM generate_series(0, pg_relation_size('w')/8192-1) b, heap_page_items(get_raw_page('w', b::int))"
    check e6b_raw_tuples_4000 test "$(qa $P lab "SELECT count(*) FROM generate_series(0, pg_relation_size('w')/8192-1) b, heap_page_items(get_raw_page('w', b::int)) WHERE t_xmin IS NOT NULL")" -eq 4000
    echo "--- pg_dump -t w: data lines in dump"
    DR=$(pg_dump -p $P -d lab -t w 2>&1 | grep -cE '^[0-9]+	[0-9]+$'); echo $DR
    check e6b_pg_dump_silently_outputs_3000 test "$DR" -eq 3000
    echo "--- amcheck verify_heapam(w)"
    q $P lab "SELECT count(*) AS amcheck_msgs FROM verify_heapam('w')"
    check e6b_amcheck_detects test "$(qa $P lab "SELECT count(*) FROM verify_heapam('w')")" -gt 0
    q $P lab "SELECT blkno, offnum, msg FROM verify_heapam('w') LIMIT 2"
    echo "--- write in multi-user"
    q $P lab "INSERT INTO w VALUES (9,9)" | head -1
    stop $N
  fi
done
say "6a-3: final state: multi-user VACUUM on the collapsed table"
start $N
q $P lab "SELECT batch, count(*) FROM w GROUP BY batch ORDER BY 1"
q $P lab "SELECT count(*) AS amcheck_msgs FROM verify_heapam('w')"
q $P lab "SELECT msg FROM verify_heapam('w') LIMIT 2"
q $P lab "VACUUM (VERBOSE) w" 2>&1 | grep -E 'ERROR|WARNING|DETAIL|CONTEXT|removable|new relfrozenxid|tuples:' | head -6
check e6_vacuum_fails_data_corrupted_XX001 test "$(qs $P lab "VACUUM w")" = XX001
log_audit $N 'does not exist|needs to be frozen'
drop_cluster $N

say "6c: pg_resetwal -x misuse (jump next XID by +2^31); catalogs frozen beforehand"
P=5507; N=e6c; D=$LAB/$N
new_cluster $N $P
q $P postgres "CREATE TABLE v AS SELECT g AS id FROM generate_series(1,100000) g"
q $P postgres "CREATE TABLE vf AS SELECT g AS id FROM generate_series(1,100000) g"
freeze_all_but $P postgres v
for db in template1; do vacuumdb -q -p $P --freeze -d $db; done
CUR=$(qa $P postgres "SELECT pg_current_xact_id()::text")
stop $N
NEW=$(( (CUR + 2147483648 + 1048576) / 1048576 * 1048576 ))
SEG=$(printf '%04X' $(( NEW / 1048576 )))
echo "current xid=$CUR -> pg_resetwal -x $NEW (zero-filled pg_xact/$SEG created as the docs instruct)"
dd if=/dev/zero of=$D/pg_xact/$SEG bs=8192 count=32 2>/dev/null
pg_resetwal -x $NEW -D $D 2>&1
start $N
q $P postgres "SELECT (SELECT count(*) FROM v) AS v_unfrozen, (SELECT count(*) FROM vf) AS vf_frozen"
check e6c_unfrozen_rows_gone test "$(qa $P postgres "SELECT count(*) FROM v")" -eq 0
check e6c_frozen_rows_intact test "$(qa $P postgres "SELECT count(*) FROM vf")" -eq 100000
q $P postgres "SELECT datname, age(datfrozenxid) FROM pg_database"
q $P postgres "INSERT INTO v VALUES (0)" | head -1
log_audit $N
finish
