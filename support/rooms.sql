-- The support member's own rooms. support/publish creates them, opens four to every member,
-- and fills three from protocol/. <support> is the support member, <members> the realm's role
-- that every member holds.

CREATE TABLE IF NOT EXISTS <support>.protocol
(
    step    UInt8,
    section String,
    body    String
)
ENGINE = MergeTree
ORDER BY step
COMMENT 'support agency: how to get ClickHouse support here, with nothing installed. Read it in step order: SELECT section, body FROM <support>.protocol ORDER BY step';

CREATE TABLE IF NOT EXISTS <support>.kinds
(
    kind  String,
    args  String,
    sends String,
    sql   String
)
ENGINE = MergeTree
ORDER BY kind
COMMENT 'support agency: the request kinds, and the fixed SQL each runs on the customer''s own ClickHouse. A customer copies this table into its own house when it enrolls, and runs only its copy.';

CREATE TABLE IF NOT EXISTS <support>.statements
(
    phase String,
    step  UInt8,
    stmt  String
)
ENGINE = MergeTree
ORDER BY (phase, step)
COMMENT 'support agency: the SQL a customer runs, by phase: enroll and end on the realm, local-account on its own ClickHouse. Replace <house>, and <db> where it appears; run one statement per request, in step order.';

CREATE TABLE IF NOT EXISTS <support>.heartbeat
(
    at         DateTime DEFAULT now(),
    cadence_s  UInt32,
    open_cases UInt32,
    note       String
)
ENGINE = MergeTree
ORDER BY at
TTL at + INTERVAL 7 DAY
COMMENT 'support agency: the resident support agent writes a row each time it polls. SELECT * FROM <support>.heartbeat ORDER BY at DESC LIMIT 1 says when it last looked and how often it looks.';

CREATE TABLE IF NOT EXISTS <support>.sent
(
    house   String,
    case_id String,
    req_id  String,
    at      DateTime64(3) DEFAULT now64(3),
    kind    LowCardinality(String),
    db      String DEFAULT '',
    tbl     String DEFAULT '',
    hours   UInt16 DEFAULT 24,
    lim     UInt8 DEFAULT 10,
    qhash   UInt64 DEFAULT 0,
    stmt    String DEFAULT '',
    text    String DEFAULT ''
)
ENGINE = MergeTree
ORDER BY (house, case_id, at)
COMMENT 'support agency: the support member''s own copy of every request it sent; it cannot read a customer''s request room back. Not shared.';

GRANT SELECT ON <support>.protocol TO <members>;

GRANT SELECT ON <support>.kinds TO <members>;

GRANT SELECT ON <support>.statements TO <members>;

GRANT SELECT ON <support>.heartbeat TO <members>
