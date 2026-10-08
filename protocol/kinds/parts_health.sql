-- kind: parts_health
-- args: none
-- sends: per table: the most active parts in one partition, active parts, merges running
SELECT database, table, max(c) AS max_parts_in_one_partition, sum(c) AS active_parts,
       (SELECT count() FROM system.merges) AS merges_running
FROM (SELECT database, table, partition_id, count() AS c FROM system.parts
      WHERE active AND database NOT IN ('system', 'INFORMATION_SCHEMA', 'information_schema')
      GROUP BY database, table, partition_id)
GROUP BY database, table
ORDER BY max_parts_in_one_partition DESC
LIMIT 50
FORMAT JSONEachRow
