-- kind: slow_queries
-- args: hours (1-168), lim (1-20)
-- sends: per query shape (normalizeQuery, then every quoted string and number replaced by ?): runs, p50 and max ms, average rows and bytes read, memory
SELECT toString(normalized_query_hash) AS qhash,
       replaceRegexpAll(normalizeQuery(any(query)), $$'(?:[^'\\]|\\.)*'|\b[0-9]+(?:\.[0-9]+)?\b$$, '?') AS query_shape,
       count() AS runs,
       round(quantile(0.5)(query_duration_ms)) AS p50_ms,
       max(query_duration_ms) AS max_ms,
       round(avg(read_rows)) AS avg_read_rows,
       round(avg(read_bytes)) AS avg_read_bytes,
       round(avg(memory_usage)) AS avg_memory_bytes
FROM system.query_log
WHERE event_date >= today() - 8 AND event_time >= now() - toIntervalHour({hours:UInt16})
  AND type = 'QueryFinish' AND query_kind = 'Select' AND NOT has(databases, 'system')
GROUP BY normalized_query_hash
ORDER BY sum(query_duration_ms) DESC
LIMIT {lim:UInt8}
FORMAT JSONEachRow
