-- XID/MXID 周回リスクの統合診断 (現在の DB で実行。クラスタ共通の項目も含む)
-- 「凍結を止めているもの」を1つの結果に並べる。age が大きい順。
\pset footer off
SELECT 'database' AS kind, datname AS name,
       age(datfrozenxid) AS xid_age, mxid_age(datminmxid) AS mxid_age, NULL::text AS detail
FROM pg_database
UNION ALL
SELECT 'backend_xmin', pid::text || ' ' || coalesce(application_name,'') || ' (' || coalesce(state,'') || ')',
       greatest(age(backend_xid), age(backend_xmin)), NULL,
       left(query, 50)
FROM pg_stat_activity WHERE (backend_xid IS NOT NULL OR backend_xmin IS NOT NULL) AND pid <> pg_backend_pid()
UNION ALL
-- xmin を持たない「ロックだけ保持」の犯人は上には出ない (E13b)。ロック待ちの autovacuum ワーカーから辿る
SELECT 'autovacuum_blocked', a.pid::text || ' blocked by ' || pg_blocking_pids(a.pid)::text,
       age(c.relfrozenxid), NULL, left(a.query, 50)
FROM pg_stat_activity a
LEFT JOIN pg_stat_progress_vacuum p ON p.pid = a.pid
LEFT JOIN pg_class c ON c.oid = p.relid
WHERE a.backend_type = 'autovacuum worker' AND a.wait_event_type = 'Lock'
UNION ALL
SELECT 'prepared_xact', gid, age(transaction), NULL, 'prepared ' || prepared::text
FROM pg_prepared_xacts
UNION ALL
SELECT 'replication_slot', slot_name || ' (' || slot_type || coalesce(', ' || invalidation_reason, '') || ')',
       greatest(age(xmin), age(catalog_xmin)), NULL,
       'active=' || active || ' xmin=' || coalesce(xmin::text,'-') || ' catalog_xmin=' || coalesce(catalog_xmin::text,'-')
FROM pg_replication_slots
UNION ALL
SELECT 'temp_table', n.nspname || '.' || c.relname, age(c.relfrozenxid), mxid_age(c.relminmxid), 'owner session cannot be vacuumed by others'
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relpersistence = 't' AND c.relkind IN ('r','t','m')
UNION ALL
SELECT 'oldest_table', c.oid::regclass::text, age(c.relfrozenxid), mxid_age(c.relminmxid),
       pg_size_pretty(pg_total_relation_size(c.oid))
FROM (SELECT oid, relfrozenxid, relminmxid FROM pg_class
      WHERE relkind IN ('r','t','m') AND relpersistence <> 't' ORDER BY age(relfrozenxid) DESC LIMIT 3) c
ORDER BY xid_age DESC NULLS LAST;
