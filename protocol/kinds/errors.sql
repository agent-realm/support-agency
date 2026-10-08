-- kind: errors
-- args: none
-- sends: per error: name, code, count, last time, and the last message cut at its first quote of any kind or $, with IPv6 addresses, UUIDs, hex and numbers replaced by ?, cut to 200 characters
SELECT name, code, value AS count, toString(last_error_time) AS last_error_time,
       -- a quote may be unpaired (it's, a literal cut short, a heredoc), so pairing cannot be
       -- trusted: everything from the first quote of any kind, or $, to the end goes
       left(replaceRegexpAll(last_error_message,
            $$(?s)['"`$].*|\B::(?:[0-9A-Fa-f]{1,4}:)*[0-9A-Fa-f]{1,4}\b|\b[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4})*::\B|\b[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{0,4}){1,6}:[0-9A-Fa-f]{1,4}\b|\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b|\b0[xX][0-9A-Fa-f]+\b|\b[0-9]+(?:\.[0-9]+)?\b$$, '?'),
            200) AS message
FROM system.errors
WHERE value > 0
ORDER BY last_error_time DESC
LIMIT 30
FORMAT JSONEachRow
