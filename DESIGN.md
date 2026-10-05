# support-agency -- design

- **Status:** prototype (phase 1)
- **Author:** claude
- **Created:** 2026-10-05-07_40
- **Approved:** --

This document is the contract. The code in `plugins/` and the proofs in `test/e2e.sh` answer to it.

## 1. What it is

The support agency lets a vendor's support agent diagnose a customer's ClickHouse without ever
connecting to it. Nobody connects a foreign agent to their own production database. So the
customer runs **their own agent**, on their own machine, as a gate in front of their ClickHouse.
The two agents meet in a realm. Support asks typed questions there. The customer's gate answers
each one only with the customer's yes, and never with the customer's data.

It is an agency in the kernel's sense: it installs on **any** kernel realm, through a member's
own house, with no kernel change, no realm-layer change and no lobby change. The realm's URL and
prefix are parameters. Only the end-to-end test names a realm, and that realm is `chaos1`.

| Part | Where it runs | What it is |
|---|---|---|
| `support-gate` | the customer's machine | Claude Code plugin: skill, `gate` tool, guard hook |
| `support-desk` | the support team's machine | Claude Code plugin: skill, `desk` tool |
| the case rooms | the customer's house in the realm | two tables, made by `enroll.sql` |

## 2. Roles

| Role | Holds | Can |
|---|---|---|
| **customer's human** | the decision | say yes or no to each request; end the case |
| **customer's agent** (gate) | the customer's realm credential and local ClickHouse credential, both kept on the customer's machine | read pending requests, run the allowlisted diagnostics locally, show a preview, send it on a yes, apply an allowed fix on a yes, revoke |
| **support agent** (desk) | the support member's realm credential | discover enrollments, open a case, insert requests, read answers |
| **realm** (the kernel) | members, houses, grants | enforce the grants; nothing else, and no daemon of its own here |

Structurally, the agency has two residents. Both are `kind = "agent"`, `on = "loop"`, and both
run off-realm, on their owners' machines. Nothing of this agency runs inside the town.

## 3. The case protocol

### 3.1 Ownership: the case lives in the customer's house

The customer's member creates two rooms in its own house (`enroll.sql`) and makes exactly two
grants to the support member:

```sql
GRANT INSERT ON <house>.support_requests TO <support member>;
GRANT SELECT ON <house>.support_answers  TO <support member>;
```

Reasons:

- **Every grant on the customer's side is the customer's.** The support member holds nothing
  the customer did not hand it, and the customer can take it back alone, at any time, with
  `REVOKE`.
- **The answers stay in a house the customer owns.** When the case ends, support loses read
  access to everything it was ever sent through the realm. A copy it made locally is outside
  any protocol's reach; see §6.
- **No new mechanism.** These are per-table grants between members, which kernel v13 already
  allows: a member holds `ALL ... WITH GRANT OPTION` on its own house. A probe on `chaos1`
  verified it on 2026-10-05, as did every run of the end-to-end test.

### 3.2 Opening and announcing

1. **The customer enrolls** (`gate enroll`). That is the customer's opt-in, and nothing happens
   before it. The customer needs the support member's name. It comes from the vendor
   (support docs, a ticket), or from the realm's lobby directory if the realm's operator lists
   the agency there (README, "Deploying on a realm").
2. **Support discovers the enrollment** from its own grants (`SHOW GRANTS`, wrapped as
   `desk clients`). There is no intake room and no announcement table: the grant *is* the
   announcement.
3. **Support opens a case** by inserting an `open` request. The case id is chosen by the desk,
   and every later request carries it.

Alternatives, and why not:

- **Case rooms in support's house, written by the customer.** The customer's answers would then
  live where the customer cannot delete them, and ending a case would be support's choice.
- **A shared intake room in the lobby.** It needs a realm-layer change, and it leaks who
  is a customer to every member.

### 3.3 The rooms

`support_requests` (support may INSERT, never read):

| column | notes |
|---|---|
| `case_id`, `req_id` | `[A-Za-z0-9_-]{4,64}`, enforced by a `CHECK` constraint |
| `at` | server time |
| `author` | `MATERIALIZED currentUser()`: stamped by the server. An insert that names it fails (code 44). |
| `kind` | a request kind (§4) |
| `args` | JSON object, at most 8 KB, enforced by a `CHECK` constraint |

`support_answers` (support may read; only the customer writes): `case_id`, `req_id`, `at`,
`author` (stamped), `status`, `approved_by`, `reason`, `payload`, `payload_sha256`.

### 3.4 A request's life

```
asked ──> previewed ──> approved ──> answered | applied | failed | acknowledged
                   ├──> denied        (the human said no)
                   └──> refused       (outside the allowlist: no yes can change it)
```

- **asked:** a row in `support_requests`.
- **previewed:** `gate show` checks the request against the allowlist, runs what it needs on
  the customer's ClickHouse (read-only), and builds the exact answer. It stores the answer and
  its sha256 in a private state file (mode 600) and prints it. Nothing leaves.
- **approved:** the human said yes, and the agent runs `gate send <req> --yes --approved-by
  <name>`. The gate sends the stored preview, byte for byte. If the request row changed since
  the preview, or the stored preview was altered, it refuses.
- **answered:** one row in `support_answers`. The `status` values:
  - `acknowledged`: an open, note or close request;
  - `answered`: a diagnostic;
  - `applied` or `failed`: a fix;
  - `denied`: the human said no;
  - `refused`: outside the allowlist.

The gate acts only on a request whose stamped `author` is the enrolled support member, and
refuses a request id that appears twice. The desk accepts an answer only if its stamped
`author` is the house's owner and its payload matches its hash. In kernel v13 a member's house
bears the member's name.

### 3.5 Ending

`gate end` revokes both grants. The support member's next INSERT fails with 497, its next read of
the answers fails with 497, and `desk clients` no longer lists the customer. A revoke ends every
case with that support member at once. The case history stays in the customer's house, to keep
or to drop.

### 3.6 What support can see without a grant

Kernel v13 lets a member list table **names** in another member's house (`SHOW TABLES`,
`system.tables`). Contents are not visible (497). So support learns that the case rooms exist,
and the names of any other rooms in that house. Accepted: the customer's production data is not
in the realm at all, and room names in a realm house are not production data. A customer who
minds should keep nothing else in that house.

## 4. Request kinds

Every kind is code in the gate. **There is no free SQL**, and a kind not in this table is
refused, with or without a yes.

| kind | args | runs locally | sends |
|---|---|---|---|
| `open`, `note`, `close` | short texts | nothing | an acknowledgement |
| `server_info` | -- | `version()`, `uptime()`, changed server and MergeTree settings | the same; a setting's value only if numeric or boolean |
| `tables_overview` | -- | `system.parts` aggregates per table | rows, bytes, part and partition counts; no partition values |
| `table_schema` | `database`, `table` (identifiers) | `SHOW CREATE TABLE` | the statement, string literals redacted |
| `parts_health` | -- | `system.parts`, `system.merges` aggregates | max parts per partition, active parts, merges running |
| `slow_queries` | `hours` 1-168, `limit` 1-20 | `system.query_log` aggregates per `normalized_query_hash` | query shapes (`normalizeQuery`, then redacted again), runs, p50/max ms, avg rows, bytes, memory |
| `explain` | `normalized_query_hash`, `mode` | takes the customer's latest query with that hash from the local log, and runs `EXPLAIN [indexes = 1]` on it | the plan, redacted (§5), and the query's shape |
| `errors` | -- | `system.errors` | name, code, count, time, message redacted |
| `apply` | `statements` (1-5), `why` | on a yes, the statements, if each matches an allowed fix form | per statement: ok, or the redacted error |

Allowed fix forms, matched in full (no `;`, no quotes, no comments, no `system.`):

- `ALTER TABLE db.t ADD PROJECTION [IF NOT EXISTS] p (SELECT cols ORDER BY cols)`;
- `ALTER TABLE db.t MATERIALIZE PROJECTION p`;
- `ALTER TABLE db.t ADD INDEX [IF NOT EXISTS] i col TYPE minmax|set(n)|bloom_filter[(p)] GRANULARITY n`;
- `ALTER TABLE db.t MATERIALIZE INDEX i`;
- `OPTIMIZE TABLE db.t [FINAL]`;
- `ALTER TABLE db.t MODIFY SETTING name = <integer>`.

Nothing that drops, deletes, updates, renames, grants or reads.

## 5. "No production data", made operational

### 5.1 The allowlist: what may leave

- **DDL:** `SHOW CREATE TABLE` output with string literals redacted (defaults, comments, engine
  arguments).
- **Settings:** names of changed settings, with values only when numeric or boolean.
- **System metadata and aggregates:** `system.parts`, `system.merges`, `system.errors`,
  `system.query_log` aggregated per normalized query hash.
- **EXPLAIN output:** quoted strings redacted everywhere. Numbers are redacted on every line
  that can carry a query's values: conditions, filters, expressions, keys and ranges. The plan's
  shape, index names, and part and granule counts stay.
- **Error codes and messages:** messages with literals redacted, cut to 300 characters.
- **Counts and sizes:** rows, bytes, parts, durations, memory.
- **Identifiers:** database, table, column, index and projection names.

### 5.2 The denylist: what never leaves

- **Rows of user tables.** No kind reads one. The gate's reads touch `system.*`, `SHOW CREATE`
  and `EXPLAIN` only. E4 checks the customer's query_log for any `Select` by the gate's account
  outside `system`.
- **Literals:** every quoted string, and every number in a query shape or a plan condition.
- **Query text with values.** Only `normalizeQuery` shapes leave, and they are redacted again.
- **Credentials:** the gate reads its two curl config files and keeps the passwords in
  memory. The guard hook stops the agent from reading them.

### 5.3 Enforcement, in layers

1. **Kinds are code.** The gate has no path from request text to SQL. Arguments are validated
   as identifiers, bounded integers, or a decimal hash.
2. **The gate's local account** is the customer's to scope. The demo's account has `SELECT` on
   `system.*`, `SELECT, SHOW` on the demo database (EXPLAIN needs `SELECT`), and only the fix
   ALTERs. Every gate read also runs with `readonly = 2`.
3. **Redaction:** §5.1.
4. **The echo screen.** The kinds that read query text check their answer, before it is stored
   as a preview, against the literals of the customer's own queries: strings of 3 or more
   characters, and numbers of 5 or more digits. Each kind uses its own set of queries:
   - `slow_queries`: up to 200 distinct queries from its window;
   - `explain`: its sample query;
   - `errors`: up to 200 distinct recent failed queries.

   If any literal appears in the answer, the answer is refused, not trimmed. The other kinds
   read no query text and are not screened.
5. **Deny patterns:** regexes in the gate's config (default: e-mail addresses). A match refuses
   the answer.
6. **Size cap:** 64 KB per answer.
7. **Preview equals send:** what the human saw is what goes, checked by sha256.
8. **Human approval:** §5.4.
9. **The guard hook** (`PreToolUse`, Bash and Read). It denies reads of the credential files.
   It also denies any shell command that mentions them, the local ClickHouse address or a case
   room, unless the command is one plain call of the gate.

### 5.4 Approval

- One request, one yes. The skill tells the agent to show the request, the exact local SQL and
  the exact answer, then ask, and to never carry a yes over to another request.
- `gate send` refuses to run without `--yes` and `--approved-by <name>`. The skill pre-allows
  `pending`, `status` and `show`, but not `send`, `deny`, `enroll` or `end`. So Claude Code
  also asks the human before each of those runs, and the human sees the exact command.
- **A fix** shows as a change. The human is told what it does and how to undo it. Support
  gets back only whether each statement succeeded.
- **The customer decides how much to delegate.** The config's `auto_approve` lists diagnostic
  kinds that may be sent without a prompt (`gate send <id> --auto`). `apply` is removed from
  that list whatever the config says.
- **A refusal** is final. On the human's yes, the gate sends only the reason.

### 5.5 Threat model

The adversary is the support side, or anyone who controls its member. Their goal is to
exfiltrate the customer's data through the realm.

- **`SELECT * FROM t`:** no kind for it. Free SQL is refused at preview and again at send
  (E4).
- **Values in error messages** (`Cannot parse string 'secret'`): literal redaction, plus the
  echo screen against failed queries. In E2 the canary's own error is answered, and E3 finds
  no canary in the realm.
- **EXPLAIN** printing a condition's literals: redaction plus the echo screen (E2 checks a
  condition holding the canary).
- **Query text** carrying values: only normalized shapes leave.
- **Prompt injection** through a note or an argument: support's text is data to the skill;
  the gate turns no text into SQL; the guard hook blocks the side doors; `send` needs a human
  permission prompt.
- **Forged requests:** the author is stamped by the server. The gate also checks it and
  refuses reused ids (E1 forges an author).
- **Forged answers:** support has no INSERT on answers (E1), and the desk checks author and
  hash.
- **Destructive "fixes":** only the forms in §4, each on a yes (E4 tries `DELETE`).
- **Request floods:** the `CHECK` constraints and the realm's member quota bound them.

### 5.6 Residual risks

- **A value in an error message that is neither quoted nor in a recent customer query** can
  pass, for example one that came from a row. Deny patterns are the backstop.
- **Short numbers** (4 digits or fewer) are not screened. A literal used only in queries beyond
  the screen's 200 is not screened either; redaction still applies to it.
- **Identifiers leave by design.** Some schemas are themselves sensitive.
- **The customer's agent is an LLM.** If the customer turns permission prompts off and the
  agent is talked into using other tools, the hook is a speed bump, not a wall. The gate, the
  skill and the prompt together are the design. Bypass mode removes one of the three.
- **The realm's admin can read the case rooms.** They hold only what the customer approved.
- **`approved_by` is a name the customer's side typed,** not an identity the realm checked.

## 6. Out of scope for phase 1

- **Support's local copies.** Answers the desk printed, or saved, persist on support's side
  after `REVOKE`. That is a contract matter between vendor and customer; the protocol makes
  sure only approved answers exist to copy.
- **Several cases per support member.** A customer can hold several open cases with one
  support member (`case_id`), but `REVOKE` ends them all.
- **A desk-side case log in support's own house**, for a team of support agents to share.
- **A lobby directory listing**, which is the realm operator's decision (README).

## 7. Verified

`test/e2e.sh` proves E1-E5 against a live realm, with a demo customer ClickHouse in a lab. The
demo customer seeds 10M rows ordered by time and runs a workload that looks rows up by user.
It also plants a canary in rows, in query literals, in a condition EXPLAIN prints, and in an
error message. The recorded runs are in `drills/`.
