-- kind: server_info
-- args: none
-- sends: version, uptime, and the names of changed server and MergeTree settings; a value only when it is a plain number or true/false
SELECT
    version() AS version,
    uptime() AS uptime_s,
    (SELECT groupArray((name, if(match(value, $$^(-?[0-9]{1,18}(\.[0-9]{1,9})?|true|false)\z$$), value, '(redacted)')))
       FROM system.server_settings WHERE changed) AS server_settings_changed,
    (SELECT groupArray((name, if(match(value, $$^(-?[0-9]{1,18}(\.[0-9]{1,9})?|true|false)\z$$), value, '(redacted)')))
       FROM system.merge_tree_settings WHERE changed) AS merge_tree_settings_changed
FORMAT JSONEachRow
