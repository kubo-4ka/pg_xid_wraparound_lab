#!/bin/bash
# 共通ヘルパ (postgres ユーザで実行)
#  - 期待結果は check / expect_state で判定し、最後に finish が PASS/FAIL を集計して終了コードを返す
#  - レポートに載せる数値は metric で "METRIC name=value" として出力し、build_report.js が拾う
export PATH=/usr/pgsql-18/bin:$PATH
LAB=/var/lib/pgsql/lab
mkdir -p $LAB
SCRIPT_NAME=$(basename "$0" .sh)
CHECK_PASS=0; CHECK_FAIL=0; CLUSTERS=()
ts(){ date '+%H:%M:%S'; }
say(){ echo; echo "===== [$(ts)] $* ====="; }
metric(){ echo "METRIC $1=$2"; }            # metric <name> <value>
now(){ date +%s.%N; }
since(){ echo "$(now) - $1" | bc | xargs printf '%.2f'; }   # since <start>

# check <name> <shell-condition...>  例: check stop_reached test "$x" = 54000
check(){
  local name=$1; shift
  if "$@"; then echo "CHECK PASS $name"; CHECK_PASS=$((CHECK_PASS+1))
  else echo "CHECK FAIL $name  (cond: $*)"; CHECK_FAIL=$((CHECK_FAIL+1)); fi
}

# 実行環境の記録 (F-07)
header(){
  echo "# script=$SCRIPT_NAME started=$(date '+%F %T %Z')"
  echo "# sha256 $(sha256sum /vagrant/scripts/$SCRIPT_NAME.sh | cut -c1-16) $SCRIPT_NAME.sh / $(sha256sum /vagrant/scripts/common.sh | cut -c1-16) common.sh"
  echo "# kernel=$(uname -r) os=$(. /etc/os-release; echo $PRETTY_NAME) cpus=$(nproc) mem_mb=$(free -m | awk '/Mem/{print $2}')"
  echo "# rpm=$(rpm -q postgresql18-server) $(postgres --version)"
  echo "# disk=$(df -h $LAB | awk 'NR==2{print $1, $2, "avail", $4}')"
}

# new_cluster <name> <port> [追加の設定行...]   (環境変数 INITDB_OPTS で initdb オプション)
new_cluster(){
  local name=$1 port=$2; shift 2
  local D=$LAB/$name
  pg_ctl -D $D stop -m immediate >/dev/null 2>&1 || true
  rm -rf $D
  initdb -D $D -E UTF8 --locale=C -A trust ${INITDB_OPTS:-} >/dev/null
  cat >> $D/postgresql.conf <<C
port = $port
shared_buffers = 512MB
max_wal_size = 4GB
logging_collector = off
log_line_prefix = '%m [%p] %b: '
log_autovacuum_min_duration = 0
autovacuum_naptime = 10s
max_prepared_transactions = 10
wal_level = logical
max_replication_slots = 10
C
  for l in "$@"; do echo "$l" >> $D/postgresql.conf; done
  pg_ctl -D $D -l $D/server.log -w start >/dev/null
  CLUSTERS+=($name)
  echo "# cluster $name: $(psql -X -At -p $port -d postgres -c "SELECT string_agg(name||'='||setting, ' ' ORDER BY name) FROM pg_settings WHERE name IN ('block_size','data_checksums','full_page_writes','wal_log_hints','autovacuum','autovacuum_freeze_max_age','vacuum_failsafe_age','autovacuum_vacuum_cost_delay','autovacuum_vacuum_cost_limit','autovacuum_max_workers','maintenance_work_mem')")"
}
start(){ pg_ctl -D $LAB/$1 -l $LAB/$1/server.log -w start >/dev/null; }
stop(){ pg_ctl -D $LAB/$1 -w stop -m fast >/dev/null; }
# q <port> <db> <sql> : 表示用 / qa: 値取得用
q(){ psql -X -v ON_ERROR_STOP=0 -p $1 -d $2 -c "$3" 2>&1; }
qa(){ psql -X -At -p $1 -d $2 -c "$3" 2>&1; }
# qs <port> <db> <sql> : 成功なら OK, 失敗なら SQLSTATE を返す (F-02: 期待エラーは SQLSTATE で判定)
qs(){
  local out; out=$(PGOPTIONS="${PGOPTIONS:-}" psql -X -At -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -p $1 -d $2 -c "$3" 2>&1)
  if [ $? -eq 0 ]; then echo OK; else
    local c=$(echo "$out" | grep -oE '(ERROR|FATAL): +[0-9A-Z]{5}' | head -1 | awk '{print $2}')
    echo ${c:-CONNFAIL}
  fi
}
maxage(){ qa $1 postgres "SELECT max(age(datfrozenxid)) FROM pg_database"; }

state(){ # <port>
  psql -X -p $1 -d postgres -c "
SELECT datname, datfrozenxid, age(datfrozenxid) AS age,
       2147483647 - 3000000 - age(datfrozenxid)::bigint AS left_to_stop,
       round(100.0*age(datfrozenxid)/2147483648,2) AS pct_to_wrap
FROM pg_database ORDER BY age DESC" 2>&1
}
# 統合診断クエリ (QA #7)
diag(){ psql -X -p $1 -d ${2:-postgres} -f /vagrant/scripts/diag.sql 2>&1; }
# ログの新規部分: logmark <name> で位置記憶, logsince <name> で差分表示
logmark(){ wc -c < $LAB/$1/server.log > /tmp/logpos_$1; }
logsince(){ local p=$(cat /tmp/logpos_$1 2>/dev/null || echo 0); tail -c +$((p+1)) $LAB/$1/server.log; }

# log_audit <name> [許容する FATAL の正規表現]
#  PANIC / No space left / 想定外 FATAL があれば FAIL (F-02)
log_audit(){
  local n=$1 allow=${2:-'^$'} L=$LAB/$1/server.log
  [ -f $L ] || return
  local panic=$(grep -cE 'PANIC:|No space left on device' $L)
  local ok="terminating (connection|autovacuum process) due to administrator command|the database system is (starting up|shutting down)"
  local fatal=$(grep -E 'FATAL:' $L | grep -vE "$ok|$allow" | wc -l)
  check "log_audit_${n}_no_panic_or_enospc" test "$panic" -eq 0
  check "log_audit_${n}_no_unexpected_fatal" test "$fatal" -eq 0
  [ "$fatal" -gt 0 ] && grep -E 'FATAL:' $L | grep -vE "$ok|$allow" | head -3
}
# 待機: wait_until <timeout_s> <shell-condition...> -> 経過秒を出力 (タイムアウト時は -1)
wait_until(){
  local to=$1; shift; local t0=$(now)
  while :; do
    if "$@" >/dev/null 2>&1; then since $t0; return 0; fi
    [ "$(echo "$(now) - $t0 > $to" | bc)" = 1 ] && { echo -1; return 1; }
    sleep 1
  done
}
lt(){ [ "$(eval "$1")" -lt "$2" ] 2>/dev/null; }   # lt "<cmd>" <n> : cmd の数値出力 < n
# consume_to_stop <port> [chunk=10000000] : 停止 (SQLSTATE 54000) まで消費し、経過秒を出力
consume_to_stop(){  # (i はローカル)
  local p=$1 c=${2:-10000000} t0=$(now) st i
  for i in $(seq 1 400); do
    st=$(qs $p postgres "SELECT consume_xids($c)")
    [ "$st" = 54000 ] && break
  done
  since $t0
}
# consume <port> <M> [db] : M 百万 XID を 10M ずつ消費
consume(){ local db=${3:-postgres} i; for i in $(seq 1 $(( $2 / 10 ))); do qa $1 $db "SELECT consume_xids(10000000)" >/dev/null; done; }
# 疑似クラッシュ (immediate shutdown -> 再起動: クラッシュリカバリが走る)
crash(){ pg_ctl -D $LAB/$1 -w stop -m immediate >/dev/null; start $1; }
# 実験終了時: ログを results/logs に退避しクラスタを削除
drop_cluster(){ # <name>...
  for n in "$@"; do
    pg_ctl -D $LAB/$n stop -m fast >/dev/null 2>&1
    cp $LAB/$n/server.log /vagrant/results/logs/$n.server.log 2>/dev/null
    rm -rf $LAB/$n
  done
}
# finish: 全クラスタを片付け、判定を集計して終了コードを返す
finish(){
  for n in "${CLUSTERS[@]}"; do [ -d $LAB/$n ] && drop_cluster $n; done
  echo
  echo "SUMMARY $SCRIPT_NAME pass=$CHECK_PASS fail=$CHECK_FAIL"
  [ $CHECK_FAIL -eq 0 ] && echo "RESULT PASS" || echo "RESULT FAIL"
  exit $([ $CHECK_FAIL -eq 0 ] && echo 0 || echo 1)
}
header
