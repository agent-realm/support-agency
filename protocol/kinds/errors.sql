-- kind: errors
-- args: none
-- sends: per error: name, code, count, last time, and the last message with every quoted string, quoted identifier and number replaced by ?, cut to 200 characters
SELECT name, code, value AS count, toString(last_error_time) AS last_error_time,
       left(replaceRegexpAll(
                -- an apostrophe inside a word (it's, doesn't) is not a quote: drop it first,
                -- so it cannot pair with a real quote and leave a literal outside the match
                replaceRegexpAll(last_error_message, $$([A-Za-z])'([A-Za-z])$$, '\\1\\2'),
                $$'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"|`[^`]*`|\b0x[0-9A-Fa-f]+\b|\b[0-9]+(?:\.[0-9]+)?\b$$, '?'),
            200) AS message
FROM system.errors
WHERE value > 0
ORDER BY last_error_time DESC
LIMIT 30
FORMAT JSONEachRow
