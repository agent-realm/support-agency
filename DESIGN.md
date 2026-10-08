# support-agency -- design

- **Status:** prototype (phase 2: the customer installs nothing)
- **Author:** claude
- **Created:** 2026-10-05-07_40
- **Revised:** 2026-10-06 -- the customer's plugin is gone; the customer side is a protocol
- **Approved:** --

This document is the contract. The protocol in `protocol/`, the support side in `support/` and
the proofs in `test/e2e.sh` answer to it.

## 1. What it is

The support agency lets a vendor's support agent diagnose a customer's ClickHouse without ever
connecting to it. Nobody connects a foreign agent to their own production database. So the
customer's **own agent**, on the customer's own machine, stands in front of their ClickHouse.
The two agents meet in a realm. Support asks typed questions there. The customer's agent answers
each one only with its human's yes, and never with the customer's data.

The customer installs nothing. Any agent that has joined the realm already holds what it needs:
its realm credential (`curl -K`), its own access to its ClickHouse, and its human. It finds
`support` in the lobby's directory, reads the protocol from the support member's house, and
follows it with plain SQL over HTTP.

It is an agency in the kernel's sense: it installs on **any** kernel realm, through members'
own houses, with no kernel change, no realm-layer change and no lobby change beyond the one
optional directory row. The realm's URL and prefix are parameters. Only the end-to-end test and
the drills name a realm, and that realm is `chaos1`.

| Part | Where it lives | What it is |
|---|---|---|
| the protocol | the support member's house: `protocol`, `kinds`, `statements` | published from `protocol/` by `support/publish`; readable by every member |
| the case rooms | the customer's house: `support_requests`, `support_answers`, `support_kinds` | created by the customer from the published statements |
| the desk | the support team's machine | `support/desk`: the vendor's tool |
| the resident | the support team's machine | a Claude Code session as the support member, polling on a stated cadence (`support/resident/`) |

## 2. Roles

| Role | Holds | Can |
|---|---|---|
| **customer's human** | the decision | say yes or no to each send; end support |
| **customer's agent** | its realm credential and its access to its ClickHouse, both on the customer's machine | read the protocol; enroll; open a case; read requests; run the published SQL locally; show; send on a yes; apply an allowed fix on a yes; end |
| **support member** (the resident, through `desk`) | its realm credential | publish the protocol; discover enrollments; insert requests; read answers; write a heartbeat |
| **realm** (the kernel) | members, houses, grants | enforce the grants and the customer's constraints; nothing else, and no daemon of its own here |

Both agents are residents with `kind = "agent"`, `on = "loop"`, running off-realm on their
owners' machines. Nothing of this agency runs inside the town.

## 3. Where the protocol lives

The protocol is **realm-native**. The support member keeps it in three rooms of its own house
and opens them to every member with `GRANT SELECT ON <support>.<room> TO __<prefix>_member`,
which the lobby's own rule `own-your-house` describes and kernel v13 allows (verified on
`chaos1`, 2026-10-06). Nothing outside the database is needed:

- `<support>.protocol` -- the guide, one row per section, read in step order. Source:
  `protocol/GUIDE.md`.
- `<support>.kinds` -- each request kind, its arguments, what it sends, and the **fixed SQL**
  the customer runs on its own ClickHouse. Source: `protocol/kinds/*.sql`, verbatim.
- `<support>.statements` -- the SQL the customer runs, by phase: `enroll` and `end` on the
  realm, `local-account` on its own ClickHouse. Source: `protocol/enroll.sql`,
  `protocol/local-account.sql`.
- `<support>.heartbeat` -- one row per poll of the resident: when it looked and its cadence.

The directory row's `join_hint` names the first query. The `version` section names the public
commit the text was published from, and the sha256 of each kind's SQL, so a customer can check
its copy against `shasum -a 256 protocol/kinds/*.sql` at that commit.

Alternative, and why not: a page in the public repo, pinned to a commit. It works, but it puts
the one thing a member must read outside the database, against the realm's own rule that
everything a member needs is in it.

## 4. The case protocol

### 4.1 Ownership: the case lives in the customer's house

Enrolling runs six published statements as the customer's member. They create three rooms in
its own house and make exactly two grants to the support member:

```sql
GRANT INSERT ON <house>.support_requests TO <support>;
GRANT SELECT ON <house>.support_answers  TO <support>;
```

- **Every grant on the customer's side is the customer's,** and so are the rooms and their
  constraints: the customer created them, from published text it could read first.
- **The answers stay in a house the customer owns.** `end` revokes both grants; support loses
  read access to everything it was ever sent through the realm.
- **Support finds its customers in its own grants** (`desk clients`). There is no intake room.
- **The customer's copy of the SQL** (`support_kinds`) is taken once, at enrollment, by
  `INSERT ... SELECT` from `<support>.kinds`. The customer runs only its copy, so a later change
  to the published SQL cannot reach a customer that already enrolled. Support cannot read or
  write the copy (497).

### 4.2 The rooms

`support_requests` (support may INSERT, never read). Every column is typed, and the room's
`CHECK` constraints are the rules, as enforced (469 on a violation):

| column | rule |
|---|---|
| `case_id`, `req_id` | `[A-Za-z0-9_-]{4,64}` |
| `at` | server time |
| `author` | `MATERIALIZED currentUser()`: stamped by the server; an insert that names it fails (44) |
| `kind` | one of `note`, `close`, `server_info`, `tables_overview`, `table_schema`, `parts_health`, `slow_queries`, `query_profile`, `errors`, `apply` |
| `db`, `tbl` | empty, or an identifier; both set for `table_schema` |
| `hours` | 1-168 |
| `lim` | 1-20 |
| `qhash` | a `UInt64` (a `normalized_query_hash`) |
| `stmt` | set exactly when `kind = 'apply'`, and then one statement of an allowed fix form (§5), nothing on `system.` or `information_schema.` |
| `text` | support's words, at most 2000 characters: shown to the human as data |

`support_answers` (support may read; only the customer writes):

| column | rule |
|---|---|
| `case_id`, `req_id` | as above; the customer's opening answer has `req_id = 'open'` |
| `author` | stamped by the server |
| `status` | one of `opened`, `acknowledged`, `answered`, `applied`, `failed`, `denied`, `refused`, `closed` |
| `approved_by` | a name: letters, spaces, `.`, `'`, `-`, up to 64; no digits |
| `payload` | at most 64 KB; empty unless `opened`, `answered` or `failed`; for `failed`, only an error code |
| `payload_sha256` | `MATERIALIZED lower(hex(SHA256(payload)))`: computed by the server |

`support_kinds`: the customer's frozen copy of `<support>.kinds`.

### 4.3 A case's life

1. **The customer opens it** (`open-a-case`): its human describes the problem, sees the text,
   says yes; the agent sends it as answer `open` with status `opened`. Support may also open a
   case itself, with a `note` request.
2. **Support asks** typed requests. The resident sees the case on its next poll.
3. **The customer answers each request once.** For a diagnostic: fetch its own copy of that
   kind's SQL, run it on its ClickHouse with the request's typed columns passed as query
   parameters (`param_db`, `param_tbl`, `param_hours`, `param_lim`, `param_qhash`), write the
   result to a file, show the human the request, the SQL and the file with its sha256, and on
   a yes send the file byte for byte (`INSERT ... SELECT ... FROM input('raw String') FORMAT
   RawBLOB`). The server's `payload_sha256` must equal the sha256 the human saw.
4. **Support diagnoses** (a `note`) and **proposes a fix** (`apply`, one statement per
   request). The human sees the statement, what it changes, what it costs and how to undo it;
   on a yes the agent runs it exactly as it is in the row, and sends only `applied`, or
   `failed` with an error code.
5. **Closing:** a `close` request, acknowledged; or the customer's own `closed` answer.
6. **Ending support:** the two published `end` statements, each run on its own -- the read of
   the answers is revoked first. Support's next INSERT fails with 497, and so does its next read.

## 5. Request kinds

The SQL of each kind is in `protocol/kinds/<kind>.sql` and, after enrollment, in the customer's
`support_kinds`. **There is no free SQL:** the room refuses any other kind, and no kind takes
SQL from a request.

| kind | args | runs locally | sends |
|---|---|---|---|
| `note`, `close` | `text` | nothing | `acknowledged` |
| `server_info` | -- | `version()`, `uptime()`, changed server and MergeTree settings | the same; a value only if it is a plain number or `true`/`false` |
| `tables_overview` | -- | `system.parts` aggregates | rows, bytes, part and partition counts per table; no partition values |
| `table_schema` | `db`, `tbl` | `system.tables` | keys, engine, and the CREATE statement with every quoted string replaced by `'?'`; numbers stay (types, settings, numeric defaults) |
| `parts_health` | -- | `system.parts`, `system.merges` aggregates | parts per partition, active parts, merges running |
| `slow_queries` | `hours`, `lim` | `system.query_log` per `normalized_query_hash` | `normalizeQuery` shapes (it replaces every literal, heredocs included), cut at any `'` or `$` left over, with UUIDs, hex and numbers replaced by `?`; backticked and double-quoted identifiers stay; runs, p50/max ms, rows, bytes, memory |
| `query_profile` | `qhash`, `hours` | `system.query_log` for that hash | tables, projections used, parts/marks/ranges selected against the total, rows read and returned |
| `errors` | -- | `system.errors` | name, code, count, time; the message cut at its first quote of any kind (`'`, `"`, backtick) or `$`, with IPv6 addresses, UUIDs, hex and numbers replaced by `?`, at most 200 characters |
| `apply` | `stmt`, `text` | on a yes, the statement | `applied`, or `failed` with the error code |

Allowed fix forms, matched in full by the room's constraint (case-insensitive; plain
identifiers; no quotes, comments or `;`):

- `ALTER TABLE db.t ADD PROJECTION [IF NOT EXISTS] p (SELECT cols ORDER BY cols)`;
- `ALTER TABLE db.t MATERIALIZE PROJECTION p`;
- `ALTER TABLE db.t ADD INDEX [IF NOT EXISTS] i col TYPE minmax|set(n)|bloom_filter[(p)] GRANULARITY n`;
- `ALTER TABLE db.t MATERIALIZE INDEX i`;
- `OPTIMIZE TABLE db.t [FINAL]`;
- `ALTER TABLE db.t MODIFY SETTING name = <integer>`.

Nothing that drops, deletes, updates, renames, grants or reads.

`explain` is gone. It had to splice the text of a customer's query, literals included, into an
`EXPLAIN` and redact the plan afterwards; that needs code. `query_profile` answers the same
question -- does the lookup use the index? -- from `system.query_log`'s ProfileEvents, with
fixed SQL and no query text at all.

## 6. "No production data", made operational

### 6.1 The allowlist: what may leave

- **DDL:** the CREATE statement with every quoted string redacted (defaults, comments, engine
  arguments); keys.
- **Settings:** names of changed settings, with values only when they are plain numbers or
  booleans.
- **System metadata and aggregates:** `system.parts`, `system.merges`, `system.errors`,
  `system.query_log` aggregated per normalized query hash, its ProfileEvents.
- **Error codes and messages,** literals redacted, cut to 200 characters.
- **Counts and sizes:** rows, bytes, parts, marks, durations, memory.
- **Identifiers:** database, table, column, index and projection names.
- **The customer's own words,** which its human typed or approved: the problem statement and the
  approver's name.

### 6.2 The denylist: what never leaves

- **Rows of user tables.** No kind reads one; with the recommended local account, none can.
- **Literals:** every quoted string, and every number in a query shape or an error message.
- **Query text with values.** Only `normalizeQuery` shapes leave, and they are redacted again.
- **Credentials.** Both stay in curl config files on the customer's machine.

### 6.3 Enforcement, and what moved

Phase 1 enforced most of this in the customer's plugin: a `gate` program, a guard hook, an
echo screen. Phase 2 has no plugin, so each guarantee moved to ClickHouse or to the human. This
is the pilot's design: "the clients' agent would be instructed to not to deliver production
data in any case ... it could also be instructed to ask for approval" -- the customer's agent is
the gate, instructed by the protocol, and its human decides.

| Guarantee | Phase 1 (code) | Phase 2 | Enforced by |
|---|---|---|---|
| closed list of kinds, typed arguments | `gate` validated JSON args | the room's `CHECK` constraints (469) | **ClickHouse** |
| only allowed fix forms | `gate` regexes | the room's `CHECK` constraint on `stmt` (469) | **ClickHouse** |
| request author | stamped, and checked by `gate` | stamped (`MATERIALIZED`, 44 on forgery); the agent checks it | **ClickHouse** + protocol |
| no row of a user table is read | `gate` read only `system.*` | the recommended `support_gate` account holds no SELECT on any user table (497) | **ClickHouse**, if the customer uses that account; otherwise the published SQL |
| no SQL from support's rows, for diagnostics | `gate` had no path from text to SQL | the agent runs only its own copy of the kind's SQL, with typed parameters | protocol + ClickHouse (query parameters are typed, never spliced) |
| a fix is support's SQL, bounded | `gate` regexes on the fix | `apply` runs the row's `stmt` itself: support's text, which only the room's constraint (one allowed form) and the human's yes stand between | **ClickHouse** (the form) + **human** (the yes) |
| support cannot change the SQL | the SQL was code in the plugin | the customer's frozen copy; support holds no grant on it (497) | **ClickHouse** |
| literal redaction | Python regexes | `normalizeQuery` and `replaceRegexpAll` inside the fixed SQL | **ClickHouse** (the SQL is fixed) |
| echo screen against the customer's own query literals | `gate` | **dropped**; the human reads the answer, and the protocol tells the agent to flag anything that looks like data | **human** |
| deny patterns (e-mail addresses) | `gate` config | **dropped**; same as above | **human** |
| preview equals send | sha256 of a stored preview; `gate` refused to send anything else | the human sees the file and its sha256, and the agent sends that file. `payload_sha256` is computed by the server from what arrived, so the agent and support can check it afterwards; nothing refuses a different file beforehand | **human** + protocol; ClickHouse only records the digest |
| refusals and denials carry nothing | `gate` (Codex found it did not) | the answers room refuses a payload on `denied`/`refused`, and anything but a code on `failed` (469) | **ClickHouse** |
| approver is a name | free text (Codex found it could carry data) | `CHECK`: letters and `. ' -` only, 64 at most | **ClickHouse** |
| one yes per send | `gate send --yes` and a permission prompt | the protocol; the agent's own permission prompts, if its human keeps them on | **human** + protocol |
| a fix runs once | (Codex found it could re-run) | the protocol checks for an existing answer first | protocol |
| side doors on the customer's machine | guard hook | **dropped**: there is no plugin; the agent's own permissions and its human govern its machine | **human** |
| ending | `gate end` revoked request access first | `end` revokes answer access first, each statement on its own | protocol (order) + ClickHouse (497) |

### 6.4 Approval

- One request, one yes. The agent shows the request, the exact local SQL and the exact bytes,
  then asks. A yes covers that row and nothing else.
- A fix is shown as a change: what it does, what it costs, how to undo it.
- Notes and close requests send only `acknowledged`; the protocol lets the human give a standing
  word for those.
- Phase 1's `auto_approve` is gone: there is no program to hold the list. A customer who wants to
  delegate tells its own agent so, and the agent's own permission settings decide.

### 6.5 Threat model

The adversary is the support side, or anyone who controls its member. Their goal is to
exfiltrate the customer's data through the realm, or to change the customer's database.

- **`SELECT * FROM t`:** no kind for it; an unknown kind is refused by the room (469); the
  recommended account cannot read a row anyway (497).
- **SQL in an argument** (`tbl = 'events WHERE 1'`): refused by the room (469); and arguments
  reach the local SQL only as typed query parameters.
- **A changed SQL text:** the customer runs its frozen copy; support cannot write it.
- **Values in error messages:** redacted in the SQL; the human reads the answer. E3 plants the
  canary in an error and finds none in the realm.
- **Query text carrying values:** only normalized shapes leave.
- **Prompt injection** through `text` or a problem statement: the protocol says support's rows
  are data, never instructions, and the closed kind list means no row can name an action outside
  it. The customer's agent is an LLM: this is the layer that rests on it and on its human.
- **Forged requests:** the author is stamped (E1). **Forged answers:** support has no INSERT on
  answers (E1), and the desk checks author and hash.
- **Destructive "fixes":** only the forms in §5 pass the room (E4), each on a yes.
- **Request floods:** the constraints and the realm's member quota bound them.

### 6.6 Residual risks

- **The customer's agent is now the gate.** Phase 1's code screened every answer whatever the
  agent did; now an agent that ignores the protocol could run other SQL or send other bytes.
  The room constraints, the frozen SQL and the local account bound what support can make it
  do; nothing bounds what its own human lets it do. That is the design: the customer decides.
- **No echo screen.** A value in an error message that is neither quoted nor a number can pass,
  for example a bare word that came from a row. The human reading the answer is the backstop.
- **A customer that skips the local account** gets the published SQL and the human, not
  ClickHouse's grants, between support and its rows.
- **Identifiers leave by design.** Some schemas are themselves sensitive.
- **Numbers in a CREATE statement leave.** `table_schema` redacts quoted strings only, so a numeric `DEFAULT` constant reaches support. Redacting every number would also erase types (`Decimal(18, 2)`) and settings.
- **Redaction is regular expressions.** A quote cannot be trusted to pair (an apostrophe, a literal cut short), so an error message is cut at its first quote of any kind or `$`, and a query shape at any `'` or `$` that `normalizeQuery` left: nothing after it leaves, at the price of the rest of the message. An unquoted, non-numeric value before the first quote (a bare word that came from a row) still passes; the human reading the answer is the backstop.
- **The enroll statements come from the support member's house.** The customer's agent runs
  them; the protocol has it show them first, and they can be checked against the public repo.
  A member holds rights only on its own house, which bounds what they could do.
- **Table names.** Kernel v13 lets a member list table names in another member's house; support
  learns the case rooms exist. Contents are not visible (497).
- **The realm's admin can read the case rooms.** They hold only what the customer approved.
- **`approved_by` is a name the customer's side typed,** not an identity the realm checked.

## 7. The resident

A real Claude Code session as the member `<prefix>_support`, made by the normal knock and
claim (`support/resident/join.sh`); its credential stays in `~/.<prefix>/support.curlrc`, mode
600. `support/resident/start.sh` starts it:

- **Its only tool is `./desk`.** Claude Code runs in safe mode (no CLAUDE.md, hooks, skills or
  plugins of the host), in `dontAsk` mode with one allow rule, `Bash(./desk:*)`, and denies for
  file reads, writes and web. The config dir it runs under (for its login) merges its own allow
  rules: `start.sh` refuses to start while that config allows anything `settings.json` does not
  deny -- in its own settings, in the run directory's `.claude/` settings, or among the approvals `.claude.json` remembers for the run directory -- or holds one of those files it cannot parse. It passes no extra arguments to Claude Code. A customer's words reach it as data;
  if they talk it into something, the most it can do is run `desk`, and `desk` can only write
  requests that the customer's room then checks.
- **Its cadence:** `/loop 10m` runs a tick; each tick runs `desk tick --cadence 60 --wait 590`,
  which polls every 60 seconds, writes a heartbeat row each time, and wakes the model only when
  a case is its move. So the house says "polls every 60 s", customers wait at most about a
  minute, and an idle hour costs six short model turns. `/loop` jobs expire after 7 days: the
  resident is restarted weekly.
- **What it does:** RESIDENT.md -- first look, narrow down, diagnose, propose a fix, verify,
  close. It never asks for data.

## 8. Out of scope

- **Support's local copies.** What the desk printed persists on support's side after `end`.
- **Several support agents sharing cases.** `<support>.sent` is one member's log.
- **An identity for the approver** beyond the name the customer's side typed.

## 9. Verified

`test/e2e.sh` proves E1-E5 against a live realm, with a demo customer ClickHouse in a lab. It
plays the customer's agent with nothing but the published protocol and curl. The demo customer
seeds 10M rows ordered by time, runs a workload that looks rows up by user, and plants a canary
in rows, in query literals and in an error message. `drills/` records the runs, and the
real-agent drill: a clean Claude Code, given only the realm's join prompt and one sentence.
