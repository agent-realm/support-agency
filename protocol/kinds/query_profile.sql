-- kind: query_profile
-- args: qhash (a qhash from slow_queries), hours (1-168)
-- sends: for that query shape: tables, projections used, and how much of each table it selected (parts, marks, ranges, rows) against the total
SELECT toString(normalized_query_hash) AS qhash,
       count() AS runs,
       any(tables) AS tables,
       groupUniqArrayArray(projections) AS projections_used,
       round(avg(read_rows)) AS avg_read_rows,
       round(avg(result_rows)) AS avg_result_rows,
       round(avg(ProfileEvents['SelectedPartsTotal'])) AS parts_total,
       round(avg(ProfileEvents['SelectedParts'])) AS parts_selected,
       round(avg(ProfileEvents['SelectedMarksTotal'])) AS marks_total,
       round(avg(ProfileEvents['SelectedMarks'])) AS marks_selected,
       round(avg(ProfileEvents['SelectedRanges'])) AS ranges_selected
FROM system.query_log
WHERE event_date >= today() - 8 AND event_time >= now() - toIntervalHour({hours:UInt16})
  AND type = 'QueryFinish' AND query_kind = 'Select' AND NOT has(databases, 'system')
  AND normalized_query_hash = {qhash:UInt64}
GROUP BY normalized_query_hash
FORMAT JSONEachRow
