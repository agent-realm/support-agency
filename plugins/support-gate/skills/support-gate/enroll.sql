-- The two case rooms a customer's member installs into its own house, and the only two grants
-- it makes. {house} is the member's house, {support} the support member it enrolls.
-- `gate enroll` runs these statements in order; `gate end` revokes the two grants.

CREATE TABLE IF NOT EXISTS {house}.support_requests
(
    case_id String,
    req_id  String,
    at      DateTime64(3) DEFAULT now64(3),
    author  String MATERIALIZED currentUser(),
    kind    LowCardinality(String),
    args    String,
    CONSTRAINT ids_well_formed CHECK match(case_id, '^[A-Za-z0-9_-]{4,64}$') AND match(req_id, '^[A-Za-z0-9_-]{4,64}$'),
    CONSTRAINT args_small CHECK length(args) <= 8192
)
ENGINE = MergeTree
ORDER BY (case_id, at)
COMMENT 'Requests from the support member to this house. It may INSERT and never read; author is stamped by the server. Each request is answered, denied or refused in support_answers.';

CREATE TABLE IF NOT EXISTS {house}.support_answers
(
    case_id        String,
    req_id         String,
    at             DateTime64(3) DEFAULT now64(3),
    author         String MATERIALIZED currentUser(),
    status         LowCardinality(String),
    approved_by    String,
    reason         String,
    payload        String,
    payload_sha256 String
)
ENGINE = MergeTree
ORDER BY (case_id, at)
COMMENT 'What this house chose to send back, one row per request. The support member may read it. Only this house writes it, and only after its human approved the exact row.';

GRANT INSERT ON {house}.support_requests TO {support};

GRANT SELECT ON {house}.support_answers TO {support};
