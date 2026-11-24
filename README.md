# pg_xid_wraparound_lab

PostgreSQL 18 の XID 周回(Transaction ID Wraparound)を実測する検証環境です。

## 構成
- VirtualBox + Vagrant, box `almalinux/9` (9.7.20260518), 4 vCPU / 4 GB
- 実験用データディスク 60 GB(`disks/lab.vdi` → `/var/lib/pgsql/lab`)
- PostgreSQL **18.6**(PGDG RPM、`provision.sh` で版を固定)と、同じ版のソース(SHA-256 検証済み)からビルドした `xid_wraparound` テストモジュール(`consume_xids()`)

## 使い方
```bash
vagrant up
```
```powershell
.\run.ps1 e02_warn_stop          # 1 シナリオ -> results\e02_warn_stop.txt, 終了コード 0=PASS / 1=FAIL
.\run_all.ps1                    # 全シナリオを順に実行 -> results\RUN_SUMMARY.txt
.\run_all.ps1 e09_many_small_tables e10_truncate_and_locks
```

## 判定と証跡
- 各スクリプトは期待結果を `check` で判定し(期待エラーは SQLSTATE で比較)、末尾の `finish` が `SUMMARY … pass=N fail=M` と `RESULT PASS|FAIL` を出して終了コードを返します。
- サーバログに `PANIC`・ディスク枯渇・想定外の `FATAL` があれば `log_audit` が FAIL にします。
- 結果ファイルの先頭に、スクリプトの SHA-256・カーネル・RPM 版・ディスク・主要 GUC を記録します。`run.ps1` はホスト側の Vagrant/VirtualBox 版を記録し、`results\MANIFEST.sha256` を更新します。

## シナリオ

| スクリプト | 内容 | 所要(この VM での実測) |
|---|---|---|
| e00_calib | 環境記録、consume_xids の速度 (3 回反復) | 1 min |
| e01_straight_autovac_on | 既定設定で 25 億 XID を消費 | 2 min |
| e02_warn_stop | ロングトランザクションで警告 → 停止 → 復旧 (autovacuum on/off、シングルユーザーモード) | 4 min |
| e03_autovac_off | autovacuum=off / freeze_max_age=20 億、4 GB 未満と超の表で failsafe の再判定を比較 | 26 min |
| e04_repl_slot | 放置スロット(物理・論理)と idle_replication_slot_timeout | 2 min |
| e05_other_blockers | pg_dump 停滞 / 2PC / 一時テーブル / idle in transaction / タイムアウト | 2 min |
| e06_visibility_collapse | シングルユーザーモード周回・pg_resetwal による可視性崩壊 | 3 min |
| e07_static_table_io | 静的テーブルの周回防止 VACUUM の I/O (3 回反復)、ロード直後凍結の因子分離、PG18 eager scanning | 19 min |
| e08_xid_burn_rates | 操作ごとの XID 消費量、pgbench での現実的な XID/s | 6 min |
| e09_many_small_tables | 2 万表の一斉周回防止 VACUUM、ワーカー数と処理能力、全速消費との競争 | 9 min |
| e10_truncate_and_locks | TRUNCATE 連発、古いスナップショット下の TRUNCATE、通常/周回防止 autovacuum とロック競合 | 6 min |
| e11_long_tx_variants | 別 DB のロングトランザクション、長時間 SELECT、スタンバイ上のクエリ | 2 min |
| e12_huge_update | 巨大表の分散更新・全行更新と、その後の周回防止 VACUUM のコスト | 27 min |
| e13_autovac_limits | テーブル単位 freeze_max_age、ロック保持だけでワーカー枯渇、実行中 VACUUM のコスト変更 | 5 min |
| e14_stale_stats | クラッシュによる統計リセット、track_counts=off、プランナ統計の陳腐化 | 2 min |
| e15_boundary_exact | 可視性境界 xmin+2^31 / 2^32 の ±1 XID 直接観測 (3 回反復) | 4 min |
| e16_recovery_drill | 可視性崩壊からの復旧演習 (pg_surgery 素朴版/慎重版 vs バックアップ復元) | 1 min |
| e17_stop_truncate_trap | 停止中の DB 全体 VACUUM が末尾切り詰めの XID 要求で失敗する罠 | 2 min |

全 18 シナリオの合計は約 2 時間です。各スクリプトは専用のクラスタを initdb し、`finish`(または途中の `drop_cluster`)でサーバログを `results/logs/` へ退避してクラスタを削除します。

**検証用 VM 専用です。** `pg_resetwal`、シングルユーザーモード、`pg_surgery` で意図的にデータを壊します。postgres ユーザの sudo は `/proc/sys/vm/drop_caches` への書き込み(`tee`)だけに限定しています。
