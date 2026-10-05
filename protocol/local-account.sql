-- The account your agent uses for support work, on YOUR ClickHouse (never on the realm). Run
-- these as an administrator of your ClickHouse, one at a time. <db> is a database support may
-- look at; repeat its two GRANTs for each one. The account reads seven system tables and the
-- schema, and holds no SELECT on any table of yours, so no query it runs can read a row.

-- phase: local-account

CREATE USER IF NOT EXISTS support_gate IDENTIFIED WITH sha256_hash BY '<sha256 of a password you generate>';

GRANT SELECT ON system.query_log TO support_gate;

GRANT SELECT ON system.parts TO support_gate;

GRANT SELECT ON system.merges TO support_gate;

GRANT SELECT ON system.errors TO support_gate;

GRANT SELECT ON system.tables TO support_gate;

GRANT SELECT ON system.server_settings TO support_gate;

GRANT SELECT ON system.merge_tree_settings TO support_gate;

GRANT SHOW TABLES, SHOW COLUMNS ON <db>.* TO support_gate;

GRANT ALTER ADD PROJECTION, ALTER MATERIALIZE PROJECTION, ALTER ADD INDEX, ALTER MATERIALIZE INDEX, ALTER MODIFY SETTING, OPTIMIZE ON <db>.* TO support_gate;
