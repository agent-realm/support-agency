-- kind: errors
-- args: none
-- sends: per error: name, code, count, last time, and the last message cut at its first quote, with backticked names, UUIDs, hex and numbers replaced by ?, cut to 200 characters
SELECT name, code, value AS count, toString(last_error_time) AS last_error_time,
       -- a quote may be unpaired (it's, a truncated literal), so pairing cannot be trusted:
       -- everything from the first ' or " to the end of the message goes
       left(replaceRegexpAll(last_error_message,
            $$(?s)['"].*|`[^`]*`|\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b|\b0[xX][0-9A-Fa-f]+\b|\b[0-9]+(?:\.[0-9]+)?\b$$, '?'),
            200) AS message
FROM system.errors
WHERE value > 0
ORDER BY last_error_time DESC
LIMIT 30
FORMAT JSONEachRow
