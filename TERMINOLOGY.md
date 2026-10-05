# Terminology

The canon is `ultimagent/TERMINOLOGY.md` in the `agent-realm` constellation. If a word here
disagrees with it, the canon wins.

Most component repos carry a verbatim copy of the canon. This one carries a pointer instead,
because the canon cites kernel specifications, and kernel material stays out of this repo.

## In this repo

| Term | Here |
|---|---|
| **agency** | the support agency: what a customer and a support team install on a realm |
| **house** | the customer member's house, which holds the case rooms; the support member's house, which holds the published protocol and the heartbeat |
| **room** | the case rooms (`support_requests`, `support_answers`, `support_kinds`) and the support member's rooms (`protocol`, `kinds`, `statements`, `heartbeat`, `sent`) |
| **member** | the customer's member, and the support member (machine register: principals) |
| **resident** | the customer's agent and the resident support agent. Both are `kind = "agent"`, `on = "loop"`, and run off-realm on their owners' machines. |
| **operator** | the realm's operator. The agency needs nothing from them but the optional lobby directory row. |

Local words:

| Word | Meaning |
|---|---|
| **gate** | the customer's agent, following the protocol: the only bridge between the customer's ClickHouse and the realm. `support_gate` is the support-only account the protocol recommends on the customer's ClickHouse. |
| **desk** | `support/desk`, the support member's tool |
| **the resident** | the Claude Code session that runs as the support member and works every case |
| **protocol** | the guide, kinds and statements the support member publishes in its house; the customer's side is nothing else |
| **kind** | a request kind: a closed list, each with fixed published SQL |
| **case** | one support matter. The customer opens it with a problem statement (answer `open`, status `opened`), or support with a note; every row carries its `case_id`. |
| **request** | a row in `support_requests`. It always has a kind and typed arguments; there is no free SQL. |
| **answer** | a row in `support_answers`, with a status: opened, acknowledged, answered, applied, failed, denied, refused or closed |
| **enroll / end** | the customer creating its case rooms and granting, and revoking, the support member's two grants |
| **the file** | the exact answer the customer's agent would send, shown to the human with its sha256 before a yes; the server computes `payload_sha256` from what arrived |
| **canary** | a random string the test plants in the demo customer's data and queries. It must never appear in the realm. |

The public register applies to the README's top half and to the protocol's guide: realm,
town, agency, join, deploy, hosted.
