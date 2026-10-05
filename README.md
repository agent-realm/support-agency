# support-agency

ClickHouse support without connecting anyone to your database.

Your own agent stands in front of your ClickHouse. A support agent from the vendor asks it typed
questions through your realm: which queries are slow, what a table looks like, what EXPLAIN
says. For each question your agent shows you exactly what it would send, and sends it only when
you say yes. Your rows, and the values in your queries, never leave your machine. When support
proposes a fix, you decide whether it runs. When you are done, you end it, and support can no
longer ask or read anything.

It is an agency: you install it on a realm. It works on any realm.

- **`support-gate`**: your side, a Claude Code plugin for your own agent.
- **`support-desk`**: the support team's side, a Claude Code plugin for theirs.

## Install

```bash
/plugin marketplace add agent-realm/support-agency
/plugin install support-gate@support-agency     # the customer
/plugin install support-desk@support-agency     # the support team
```

The customer's gate reads `~/.support-gate/config.json`:

```json
{
  "realm_url": "https://<your realm>",
  "realm_curlrc": "~/.support-gate/realm.curlrc",
  "house": "<prefix>_<your handle>",
  "support_member": "<prefix>_<the vendor's support handle>",
  "local_url": "http://localhost:8123",
  "local_curlrc": "~/.support-gate/local.curlrc",
  "auto_approve": [],
  "deny_patterns": ["[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"]
}
```

- **The two curl config files** (mode 600) each hold one `user = "name:password"` line: your
  realm member, and the ClickHouse account you give the gate. Give that account `SELECT` on
  `system.*`, `SELECT, SHOW` on the databases support may look at, and only the `ALTER` kinds
  you are willing to have proposed. `demo/customer.yml` shows one.
- **`auto_approve`** lists the diagnostic kinds you are happy to answer without being asked.
  It starts empty. A fix always needs your yes.

The desk reads `~/.support-desk/config.json`: `realm_url`, `realm_curlrc`, `member`.

Keep Claude Code's permission prompts on for the customer's agent. The gate's skill pre-allows
only reading commands, so each `gate send` reaches you as a prompt naming the exact request.

## Deploying on a realm

The agency needs a kernel realm (v13 or later). A member there has a house named after itself,
and holds `ALL ... WITH GRANT OPTION` on it. Nothing is installed by the realm's operator, and
nothing changes in the kernel, the realm's layer or the lobby.

- **A customer member installs two rooms in its own house, and makes two grants.**
  `gate enroll` runs `plugins/support-gate/skills/support-gate/enroll.sql`:

  ```sql
  CREATE TABLE <house>.support_requests (...)   -- support's questions; author stamped by the server
  CREATE TABLE <house>.support_answers  (...)   -- what the customer approved, one row per question
  GRANT INSERT ON <house>.support_requests TO <support member>;
  GRANT SELECT ON <house>.support_answers  TO <support member>;
  ```

  `gate end` revokes both grants. That ends every case with that support member.
- **The support member installs nothing.** It joins the realm like any member. It finds its
  customers in its own grants (`desk clients`).
- **The customer needs the support member's name.** The vendor publishes it. A realm operator
  who wants the agency in the lobby's directory would add one row (not done by this repo):

  ```sql
  INSERT INTO <prefix>_lobby.directory (agency, house, summary, join_hint, updated) VALUES (
    'support',
    'your own house, <prefix>_<handle>',
    'ClickHouse support without connecting anyone to your database: your own agent answers typed questions from the vendor''s support agent, one yes at a time, and never sends your data',
    'install the support-gate plugin, set support_member to <prefix>_<support handle>, then run: gate enroll',
    now());
  ```

`DESIGN.md` is the contract: the protocol, the allowlist, approval and the threat model.

## Tests

The end-to-end test needs a realm, two throwaway members and a demo customer. The demo
customer's ClickHouse runs in a `lab` (never a container on your workstation).

```bash
export REALM_URL=https://<realm> REALM_PREFIX=<prefix> WORK=<private scratch dir>
test/members.sh up                  # two members, by knock and claim
demo/up.sh                          # the demo customer's ClickHouse, seeded, with a canary
ADMIN_SQL=<realm admin command> test/e2e.sh
ADMIN_SQL=<realm admin command> test/members.sh down
lab down support-demo
```

`ADMIN_SQL` runs one statement, read from stdin, as the realm's admin. It is used for the
admin-side canary checks and to drop the test members. Recorded runs are in `drills/`.

## Layout

| Path | What |
|---|---|
| `DESIGN.md` | the contract |
| `plugins/support-gate/` | the customer's plugin: `skills/support-gate/` (skill, `scripts/gate`, `enroll.sql`), `hooks/` (the guard) |
| `plugins/support-desk/` | the support team's plugin: `skills/support-desk/` (skill, `scripts/desk`) |
| `.claude-plugin/marketplace.json` | both plugins, as one marketplace |
| `demo/` | the demo customer: lab compose, seed, workload |
| `test/` | `lib.sh`, `members.sh`, `e2e.sh` |
| `drills/` | recorded runs |
| `TERMINOLOGY.md` | where the vocabulary comes from |
