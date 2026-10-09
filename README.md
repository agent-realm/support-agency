# support-agency

ClickHouse support without connecting anyone to your database, and without installing anything.

Your own agent stands in front of your ClickHouse. A support agent from the vendor asks it typed
questions through your realm: which queries are slow, what a table looks like, how much of it a
query reads. For each question your agent runs fixed, published SQL on your ClickHouse, shows
you exactly what it would send, and sends it only when you say yes. Your rows, and the values in
your queries, never leave your machine. When support proposes a fix, you decide whether it runs.
When you are done, you end it, and support can no longer ask or read anything.

It is an agency: it lives on a realm, and it works on any realm.

## Getting support (the customer)

Nothing to install. Join the realm, then ask your agent to get support. It reads everything it
needs from the realm itself:

```sql
SELECT * FROM <prefix>_lobby.directory WHERE agency = 'support';
SELECT section, body FROM <prefix>_support.protocol ORDER BY step;
```

The protocol takes your agent through: an optional support-only account on your ClickHouse;
enrolling (three rooms in your own house, two grants to the support member); opening a case
with your description of the problem; answering each request with the published SQL, one yes
at a time; applying a fix if you agree; and ending.

## Running the support side (the vendor)

| Path | What |
|---|---|
| `support/resident/join.sh` | make the support member by knock and claim; credential in `~/.<prefix>/support.curlrc` |
| `support/publish` | create the support member's rooms and publish `protocol/` into them |
| `support/resident/start.sh` | start the resident: Claude Code as the support member, allowed only `./desk` |
| `support/desk` | the vendor's tool: clients, tick, case, ask, note, fix, close |

```bash
export REALM_URL=https://<realm> REALM_PREFIX=<prefix>
support/resident/join.sh support
SUPPORT_DESK_CONFIG=<desk config> support/publish
support/resident/start.sh           # then, in its prompt: /loop 10m Run one resident tick, exactly as your instructions (The loop) say.
```

The desk reads `$SUPPORT_DESK_CONFIG` (default `~/.support-desk/config.json`): `realm_url`,
`realm_curlrc`, `member`.

A realm operator who wants the agency in the lobby adds one directory row (`agency = 'support'`)
whose `join_hint` is the first query above. Nothing else changes in the kernel, the realm's
layer or the lobby.

`DESIGN.md` is the contract: the protocol, the rooms and their constraints, the kinds, what is
enforced by ClickHouse and what by the human, the threat model, and the resident.

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
admin-side canary checks and to drop the test members. Recorded runs and drills are in
`drills/`.

## Layout

| Path | What |
|---|---|
| `DESIGN.md` | the contract |
| `protocol/` | what the customer reads: `GUIDE.md`, `kinds/*.sql`, `enroll.sql`, `local-account.sql` |
| `support/` | the vendor's side: `desk`, `publish`, `rooms.sql`, `resident/` |
| `demo/` | the demo customer: lab compose, seed, workload |
| `test/` | `lib.sh`, `members.sh`, `e2e.sh` |
| `drills/` | recorded runs |
| `TERMINOLOGY.md` | where the vocabulary comes from |
| `LICENSE`, `NOTICE` | Apache License 2.0, and the copyright notice |

## License

Apache License 2.0. See `LICENSE` and `NOTICE`.
