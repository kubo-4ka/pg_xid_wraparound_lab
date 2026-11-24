#!/bin/bash
# PostgreSQL 18 (版固定) + xid_wraparound テストモジュール(consume_xids)のビルド
set -eux
PG_MINOR=${PG_MINOR:-18.6}
timedatectl set-timezone Asia/Tokyo
dnf -qy install https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm || true
dnf -qy module disable postgresql || true
dnf config-manager --set-enabled crb
dnf -qy install epel-release || true
dnf -qy install gcc make bzip2 wget bc jq sysstat
# 版を固定 (再プロビジョニングで別の 18.x が入らないように)
dnf -qy install postgresql18-$PG_MINOR postgresql18-libs-$PG_MINOR postgresql18-server-$PG_MINOR \
                postgresql18-contrib-$PG_MINOR postgresql18-devel-$PG_MINOR
PGV=$(rpm -q --qf '%{VERSION}' postgresql18-server)
[ "$PGV" = "$PG_MINOR" ]
cd /usr/local/src
T=postgresql-$PGV.tar.bz2
[ -f $T ] || wget -q https://ftp.postgresql.org/pub/source/v$PGV/$T
[ -f $T.sha256 ] || wget -q https://ftp.postgresql.org/pub/source/v$PGV/$T.sha256
sha256sum -c $T.sha256
[ -d postgresql-$PGV ] || tar xjf $T
make -C postgresql-$PGV/src/test/modules/xid_wraparound USE_PGXS=1 PG_CONFIG=/usr/pgsql-18/bin/pg_config with_llvm=no
make -C postgresql-$PGV/src/test/modules/xid_wraparound USE_PGXS=1 PG_CONFIG=/usr/pgsql-18/bin/pg_config with_llvm=no install
cat > /etc/profile.d/pg.sh <<'X'
export PATH=/usr/pgsql-18/bin:$PATH
X
systemctl disable --now firewalld || true
# 実験用データディスク (/var/lib/pgsql/lab)
DEV=$(readlink -f /dev/disk/by-path/*-ata-2 | head -1)
blkid "$DEV" >/dev/null 2>&1 || mkfs.xfs -f -L pglab "$DEV"
mkdir -p /var/lib/pgsql/lab
grep -q LABEL=pglab /etc/fstab || echo "LABEL=pglab /var/lib/pgsql/lab xfs defaults,noatime 0 0" >> /etc/fstab
systemctl daemon-reload; mount -a
chown postgres:postgres /var/lib/pgsql/lab
# swap 2GB (メモリ 4GB でのハング対策) と永続 journal
[ -f /swapfile ] || { dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none; chmod 600 /swapfile; mkswap /swapfile; }
grep -q /swapfile /etc/fstab || echo "/swapfile none swap defaults 0 0" >> /etc/fstab
swapon -a || true
mkdir -p /var/log/journal; systemctl restart systemd-journald
# 実験スクリプトから drop_caches するため (検証用VMのみ)
echo 'postgres ALL=(root) NOPASSWD: /usr/bin/tee /proc/sys/vm/drop_caches' > /etc/sudoers.d/postgres; chmod 440 /etc/sudoers.d/postgres
df -h /var/lib/pgsql/lab
echo "provision done: PG $PGV"
