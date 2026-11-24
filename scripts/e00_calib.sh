#!/bin/bash
# E0: 環境の記録と consume_xids の速度計測 (各サイズ 3 回反復)
source /vagrant/scripts/common.sh
P=5500; N=e0
say "E0 PostgreSQL version / cluster"
new_cluster $N $P
q $P postgres "SELECT version()"
check version_18_6 test "$(qa $P postgres "SHOW server_version")" = 18.6
check ext_xid_wraparound test "$(qs $P postgres "CREATE EXTENSION xid_wraparound")" = OK
q $P postgres "SELECT name, setting FROM pg_settings WHERE name ~ 'freeze|failsafe|autovacuum$|autovacuum_max_workers|naptime|autovacuum_vacuum_cost' ORDER BY name"
echo "# pg_config --configure: $(pg_config --configure | cut -c1-300)..."
state $P
say "consume_xids speed (3 reps each; 1 call = 1 transaction)"
echo "csv,n,rep,elapsed_s,xid_per_s"
for n in 1000000 10000000 100000000; do
  for r in 1 2 3; do
    s=$(now); qa $P postgres "SELECT consume_xids($n)" >/dev/null; e=$(since $s)
    echo "csv,$n,$r,$e,$(echo "$n / $e" | bc)"
  done
done | tee /tmp/e0.csv
for n in 1000000 10000000 100000000; do
  med=$(awk -F, -v n=$n '$2==n{print $5}' /tmp/e0.csv | sort -n | sed -n 2p)
  metric rate_${n}_median $med
done
metric rate_100M_min $(awk -F, '$2==100000000{print $5}' /tmp/e0.csv | sort -n | head -1)
metric rate_100M_max $(awk -F, '$2==100000000{print $5}' /tmp/e0.csv | sort -n | tail -1)
state $P
log_audit $N
finish
