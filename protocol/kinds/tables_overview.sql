-- kind: tables_overview
-- args: none
-- sends: per table: engine, rows, bytes on disk, active parts, partition count; no partition values
SELECT database, table, any(engine) AS engine, sum(rows) AS rows, sum(bytes_on_disk) AS bytes_on_disk,
       count() AS active_parts, uniqExact(partition_id) AS partitions
FROM system.parts
WHERE active AND database NOT IN ('system', 'INFORMATION_SCHEMA', 'information_schema')
GROUP BY database, table
ORDER BY bytes_on_disk DESC
LIMIT 50
FORMAT JSONEachRow
