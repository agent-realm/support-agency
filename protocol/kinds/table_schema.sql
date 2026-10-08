-- kind: table_schema
-- args: db, tbl (identifiers)
-- sends: the table's CREATE statement with every quoted string replaced by '?', and its keys
SELECT database, name AS table, engine, sorting_key, primary_key, partition_key,
       replaceRegexpAll(create_table_query, $$'(?:[^'\\]|\\.)*'$$, '''?''') AS statement
FROM system.tables
WHERE database = {db:String} AND name = {tbl:String}
  AND database NOT IN ('system', 'INFORMATION_SCHEMA', 'information_schema')
FORMAT JSONEachRow
