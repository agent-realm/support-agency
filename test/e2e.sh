#!/usr/bin/env bash
# test/e2e.sh -- the support agency end to end, with no LLM: the desk and the gate are driven
# by this script, as the two agents would drive them.
#
#   REALM_URL=<url> REALM_PREFIX=<prefix> WORK=<private dir> [ADMIN_SQL=<command>] test/e2e.sh
#
# Needs test/members.sh up and demo/up.sh to have run with the same WORK. Without ADMIN_SQL
# the admin-side canary checks are skipped (and reported as skipped).
#
# Proofs:
#   E1  the support member alone reads nothing of the customer's house
#   E2  the full case, ending with the fix applied and the problem measured as gone
#   E3  the canary never appears in any realm room or the realm's query_log, checked as each
#       member and as admin
#   E4  a request outside the allowlist is refused, even with the customer's yes
#   E5  revoking the grants ends the case: the support member's next INSERT fails with 497
set -uo pipefail
: "${REALM_URL:?}" "${REALM_PREFIX:?}" "${WORK:?}"
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
. "$here/lib.sh"
umask 077

GATE="$root/plugins/support-gate/skills/support-gate/scripts/gate"
DESK="$root/plugins/support-desk/skills/support-desk/scripts/desk"
S=$(awk '$1 == "support" {print $2}' "$WORK/members")
H=$(awk '$1 == "customer" {print $2}' "$WORK/members")    # a member's house bears its name
LOCAL=$(cat "$WORK/local_url")
CANARY=$(cat "$WORK/canary")
half=$(( ${#CANARY} / 2 ))
# The canary is searched for as concat(a, b): a check's own text never holds it whole, so the
# checks cannot plant what they look for in the query_log.
NEEDLE="concat('${CANARY:0:$half}', '${CANARY:$half}')"

cat > "$WORK/gate.json" <<EOF
{"realm_url": "$REALM_URL", "realm_curlrc": "$WORK/customer.curlrc", "house": "$H",
 "support_member": "$S", "local_url": "$LOCAL", "local_curlrc": "$WORK/local-gate.curlrc",
 "state_dir": "$WORK/gate-state"}
EOF
cat > "$WORK/desk.json" <<EOF
{"realm_url": "$REALM_URL", "realm_curlrc": "$WORK/support.curlrc", "member": "$S"}
EOF
export SUPPORT_GATE_CONFIG="$WORK/gate.json" SUPPORT_DESK_CONFIG="$WORK/desk.json"

as_support()  { q_as "$WORK/support.curlrc" "$REALM_URL" "$@" 2>&1; }
as_customer() { q_as "$WORK/customer.curlrc" "$REALM_URL" "$@" 2>&1; }
local_admin() { q_as "$WORK/local-admin.curlrc" "$LOCAL" "$@" 2>&1; }
field() { python3 -c 'import json,re,sys; a=json.loads(sys.stdin.read() or "{}"); print(eval(sys.argv[1], {"a": a, "json": json, "re": re}))' "$1"; }

# answer REQ -- the support member's view of the answer to REQ, as one JSON line
answer() { "$DESK" answers "$H" --req "$1" --json; }

# cycle KIND [ARGS] -- the support member asks; the customer's gate previews it, and the
# customer says yes. Prints the request id.
cycle() {
  local r
  r=$("$DESK" ask "$H" "$CASE" "$@") || return 1
  "$GATE" show "$r" > "$WORK/show-$r.txt" 2>&1 || { cat "$WORK/show-$r.txt" >&2; return 1; }
  "$GATE" send "$r" --yes --approved-by "e2e customer" > "$WORK/send-$r.txt" 2>&1 || { cat "$WORK/send-$r.txt" >&2; return 1; }
  echo "$r"
}

note "realm $REALM_URL; support $S; customer $H; customer ClickHouse $LOCAL"

# --- E1: alone, the support member reads nothing ---------------------------------------
as_customer "CREATE TABLE IF NOT EXISTS $H.private_notes (k String, v String) ENGINE = MergeTree ORDER BY k" >/dev/null
as_customer "INSERT INTO $H.private_notes VALUES ('renewal', 'march, 3 seats')" >/dev/null
expect_eq "E1 before enrollment, support cannot read a customer room" \
  "$(err_code "$(as_support "SELECT count() FROM $H.private_notes")")" 497
expect_eq "E1 before enrollment, support cannot write a customer room" \
  "$(err_code "$(as_support "INSERT INTO $H.private_notes VALUES ('x', 'y')")")" 497
expect_match "E1 before enrollment, support's desk lists no customer" "$("$DESK" clients)" "no customer has enrolled you"

enroll=$("$GATE" enroll 2>&1)
expect_match "E2 the customer enrolls the support member" "$enroll" "^enrolled: $S may INSERT"
expect_match "E2 the desk discovers the enrollment from its own grants" "$("$DESK" clients)" "^$H	enrolled"
expect_eq "E1 after enrollment, support still cannot read a customer room" \
  "$(err_code "$(as_support "SELECT count() FROM $H.private_notes")")" 497
expect_eq "E1 after enrollment, support cannot read its own requests" \
  "$(err_code "$(as_support "SELECT count() FROM $H.support_requests")")" 497
expect_eq "E1 support cannot forge a request's author" \
  "$(err_code "$(as_support "INSERT INTO $H.support_requests (case_id, req_id, kind, args, author) VALUES ('c-forge', 'r-forge', 'open', '{}', '$H')")")" 44
expect_eq "E1 support cannot write an answer" \
  "$(err_code "$(as_support "INSERT INTO $H.support_answers (case_id, req_id, status) VALUES ('c-forge', 'r-forge', 'applied')")")" 497

# --- E2: the case ----------------------------------------------------------------------
RUN=$(openssl rand -hex 4)     # this run's workload tags: an earlier run's lookups never count
WORK="$WORK" "$root/demo/workload.sh" "before-$RUN"
before=$(local_admin "SELECT round(avg(read_rows)) FROM system.query_log WHERE type = 'QueryFinish'
  AND log_comment = 'before-$RUN' AND query LIKE '%WHERE user_id = %'")
expect_ge "E2 before the fix, a lookup by user reads most of the table" "$before" 5000000

opened=$("$DESK" open "$H" --title "dashboards filtered by user are slow")
CASE=$(printf '%s' "$opened" | sed -n 's/^case \([^ ]*\) .*/\1/p')
r_open=$(printf '%s' "$opened" | sed -n 's/.*(request \([^)]*\)).*/\1/p')
expect_match "E2 the desk opens a case" "$CASE" "^c[0-9]{8}-[0-9a-f]{8}$"
expect_match "E2 the gate lists the case's first request as pending" "$("$GATE" pending)" "$r_open .*open"
"$GATE" show "$r_open" >/dev/null && "$GATE" send "$r_open" --yes --approved-by "e2e customer" >/dev/null
expect_eq "E2 the customer acknowledges the case" "$(answer "$r_open" | field 'a["status"]')" acknowledged

r=$(cycle slow_queries hours=1)
SQ=$(answer "$r")
expect_eq "E2 slow_queries is answered, with the human's name on it" \
  "$(printf '%s' "$SQ" | field 'a["status"] + "/" + a["approved_by"] + "/" + str(a["verified"])')" "answered/e2e customer/True"
HASH=$(printf '%s' "$SQ" | field '[x["normalized_query_hash"] for x in json.loads(a["payload"])["result"] if "user_id" in x["query_shape"]][0]')
EHASH=$(printf '%s' "$SQ" | field '[x["normalized_query_hash"] for x in json.loads(a["payload"])["result"] if "accounts" in x["query_shape"]][0]')
expect_match "E2 support sees the slow query's shape, without its values" \
  "$(printf '%s' "$SQ" | field '[x["query_shape"] for x in json.loads(a["payload"])["result"] if "user_id" in x["query_shape"]][0]')" \
  "WHERE user_id = \?$"
expect_ge "E2 support sees how many rows a lookup reads" \
  "$(printf '%s' "$SQ" | field '[int(x["avg_read_rows"]) for x in json.loads(a["payload"])["result"] if "user_id" in x["query_shape"]][0]')" 5000000

r=$(cycle table_schema database=demo table=events)
expect_match "E2 support sees the table's sorting key" \
  "$(answer "$r" | field 'json.loads(a["payload"])["result"][0]["statement"]')" "ORDER BY event_time"

r=$(cycle explain "normalized_query_hash=$HASH")
expect_eq "E2 support sees that the lookup's EXPLAIN reads every granule" \
  "$(answer "$r" | field 'bool(re.search(r"Granules: (\d+)/\1\b", json.loads(a["payload"])["result"][0]["plan"]))')" True

r=$(cycle explain "normalized_query_hash=$EHASH")
EX=$(answer "$r")
expect_eq "E2 an EXPLAIN whose condition holds the canary is still answered" "$(printf '%s' "$EX" | field 'a["status"]')" answered
expect_match "E2 ... with that condition's literal redacted" "$(printf '%s' "$EX" | field 'json.loads(a["payload"])["result"][0]["plan"]')" "email.*'\?'"

r=$(cycle errors)
expect_eq "E2 errors are answered, messages redacted" "$(answer "$r" | field 'a["status"]')" answered

"$DESK" note "$H" "$CASE" "demo.events is sorted by event_time, but the dashboards filter by user_id, so each lookup reads all 10M rows. A projection sorted by user_id lets ClickHouse read a few granules instead; it costs one more sorted copy of the table on disk." >/dev/null

r_fix=$("$DESK" fix "$H" "$CASE" \
  --stmt "ALTER TABLE demo.events ADD PROJECTION by_user (SELECT * ORDER BY user_id)" \
  --stmt "ALTER TABLE demo.events MATERIALIZE PROJECTION by_user" \
  --why "lookups by user_id stop scanning the table")
expect_match "E2 the gate shows a fix as a change, before anything runs" "$("$GATE" show "$r_fix")" "CHANGES your ClickHouse"
expect_no_match "E2 nothing changed before the customer's yes" "$(local_admin "SHOW CREATE TABLE demo.events")" "by_user"
"$GATE" send "$r_fix" --yes --approved-by "e2e customer" >/dev/null
expect_eq "E2 the customer applies the fix; support sees only the outcome" "$(answer "$r_fix" | field 'a["status"]')" applied

WORK="$WORK" "$root/demo/workload.sh" "after-$RUN"
after=$(local_admin "SELECT round(avg(read_rows)) FROM system.query_log WHERE type = 'QueryFinish'
  AND log_comment = 'after-$RUN' AND query LIKE '%WHERE user_id = %'")
if _is_uint "$after"; then after100=$((after * 100)); else after100="$after"; fi
expect_lt "E2 after the fix, a lookup by user reads under 1% of what it did" "$after100" "$before"
note "rows read per lookup: $before before the fix, $after after"

r=$("$DESK" close "$H" "$CASE" --why "lookups by user read a few granules now")
"$GATE" show "$r" >/dev/null && "$GATE" send "$r" --yes --approved-by "e2e customer" >/dev/null

# --- E4: outside the allowlist, a yes changes nothing -----------------------------------
# A support member that ignores its desk and writes free SQL straight into the room.
as_support "INSERT INTO $H.support_requests (case_id, req_id, kind, args) VALUES ('$CASE', 'r-free-sql', 'sql', '{\"query\": \"SELECT * FROM demo.events LIMIT 10\"}')" >/dev/null
expect_match "E4 the gate refuses free SQL at preview" "$("$GATE" show r-free-sql)" "REFUSED"
"$GATE" send r-free-sql --yes --approved-by "e2e customer" >/dev/null
FREE=$(answer r-free-sql)
expect_eq "E4 ... and with the customer's yes, it sends only a refusal" \
  "$(printf '%s' "$FREE" | field 'a["status"] + "/" + str(len(a["payload"]))')" "refused/0"

r_bad=$("$DESK" fix "$H" "$CASE" --stmt "ALTER TABLE demo.events DELETE WHERE 1")
expect_match "E4 the gate refuses a fix outside the allowed forms" "$("$GATE" show "$r_bad")" "REFUSED"
"$GATE" send "$r_bad" --yes --approved-by "e2e customer" >/dev/null
expect_eq "E4 ... and with the customer's yes, it runs nothing" "$(answer "$r_bad" | field 'a["status"]')" refused
local_admin "SYSTEM FLUSH LOGS" >/dev/null
expect_eq "E4 the gate's account never read a row of a user table" \
  "$(local_admin "SELECT count() FROM system.query_log WHERE user = 'gate' AND query_kind = 'Select'
      AND NOT has(databases, 'system') AND query NOT LIKE 'EXPLAIN%' AND query NOT LIKE 'SHOW%'")" 0
expect_eq "E4 the demo table still holds every row" "$(local_admin "SELECT count() FROM demo.events")" 10000000

# --- E3: the canary never reaches the realm ---------------------------------------------
rooms_hits() {   # rooms_hits CURLRC HOUSE ROOM... -- canary hits, summed over the rooms
  local rc=$1 house=$2 t n sum=0; shift 2
  for t in "$@"; do
    n=$(q_as "$rc" "$REALM_URL" "SELECT countIf(position(formatRow('TSV', *), $NEEDLE) > 0) FROM $house.$t" 2>&1)
    _is_uint "$n" || { echo "error:$t:$n"; return; }
    sum=$((sum + n))
  done
  echo "$sum"
}
# Controls search for the case id, which is in the rooms; an empty id would match anything.
CTRL=${CASE:-"(no case was opened)"}
expect_ge "E3 control: the search finds a string that is there (the case id)" \
  "$(as_customer "SELECT countIf(position(formatRow('TSV', *), '$CTRL') > 0) FROM $H.support_answers")" 1
expect_eq "E3 as the customer: no room in its house holds the canary" \
  "$(rooms_hits "$WORK/customer.curlrc" "$H" support_requests support_answers private_notes)" 0
expect_eq "E3 as support: no answer it can read holds the canary" \
  "$(rooms_hits "$WORK/support.curlrc" "$H" support_answers)" 0
if [ -n "${ADMIN_SQL:-}" ]; then
  admin() { printf '%s' "$1" | $ADMIN_SQL 2>&1; }
  admin "SYSTEM FLUSH LOGS" >/dev/null
  for house in "$H" "$S" "${REALM_PREFIX}_lobby"; do
    tables=$(admin "SELECT name FROM system.tables WHERE database = '$house' AND engine LIKE '%MergeTree'")
    hits=0
    for t in $tables; do
      n=$(admin "SELECT countIf(position(formatRow('TSV', *), $NEEDLE) > 0) FROM $house.$t")
      _is_uint "$n" && hits=$((hits + n)) || hits="error:$t:$n"
    done
    expect_eq "E3 as admin: no room in $house holds the canary" "$hits" 0
  done
  expect_ge "E3 as admin, control: the realm's query_log holds this run's requests" \
    "$(admin "SELECT count() FROM system.query_log WHERE event_date >= today() - 1 AND position(query, '$CTRL') > 0")" 1
  expect_eq "E3 as admin: no query, and no error, in the realm's query_log holds the canary" \
    "$(admin "SELECT count() FROM system.query_log WHERE event_date >= today() - 1
              AND (position(query, $NEEDLE) > 0 OR position(exception, $NEEDLE) > 0)")" 0
else
  skip "E3 as admin (ADMIN_SQL is not set)"
fi

# --- E5: revoking ends the case ---------------------------------------------------------
expect_match "E5 the customer ends the case" "$("$GATE" end)" "^ended: $S holds no grant"
expect_eq "E5 support's next request fails with 497" \
  "$(err_code "$(as_support "INSERT INTO $H.support_requests (case_id, req_id, kind, args) VALUES ('$CASE', 'r-after-end', 'slow_queries', '{}')")")" 497
expect_eq "E5 support can no longer read the answers" \
  "$(err_code "$(as_support "SELECT count() FROM $H.support_answers")")" 497
expect_match "E5 the desk no longer lists the customer" "$("$DESK" clients)" "no customer has enrolled you"

finish
