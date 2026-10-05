# Terminology

The canon is `ultimagent/TERMINOLOGY.md` in the `agent-realm` constellation. If a word here
disagrees with it, the canon wins.

Most component repos carry a verbatim copy of the canon. This one carries a pointer instead,
because the canon cites kernel specifications, and kernel material stays out of this repo.

## In this repo

| Term | Here |
|---|---|
| **agency** | the support agency: what a customer and a support team install on a realm |
| **house** | the customer member's house, which holds the case rooms. The support member's house is unused. |
| **room** | `support_requests` and `support_answers`, the case rooms |
| **member** | the customer's member, and the support member (machine register: principals) |
| **resident** | the customer's gate and the support desk. Both are `kind = "agent"`, `on = "loop"`, and run off-realm on their owners' machines. |
| **operator** | the realm's operator. The agency needs nothing from them (an optional lobby directory row aside). |

Local words:

| Word | Meaning |
|---|---|
| **gate** | the customer's agent, with the `support-gate` plugin: the only bridge between the customer's ClickHouse and the realm |
| **desk** | the support agent, with the `support-desk` plugin |
| **case** | one support matter. It is opened by an `open` request, and every request carries its `case_id`. |
| **request** | a row in `support_requests`. It always has a kind; there is no free SQL. |
| **answer** | a row in `support_answers`, with a status: acknowledged, answered, applied, failed, denied or refused |
| **enroll / end** | the customer granting, and revoking, the support member's two grants |
| **preview** | the exact answer the gate would send, stored locally and shown to the human before a yes |
| **canary** | a random string the test plants in the demo customer's data and queries. It must never appear in the realm. |

The public register applies to the README's top half and to the plugin descriptions: realm,
town, agency, join, deploy, hosted.
