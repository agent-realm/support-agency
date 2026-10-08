#!/usr/bin/env bash
# test/e2e.sh -- the support agency end to end, with no LLM. This script plays both agents:
# the support member through support/desk, and the customer's agent through nothing but the
# protocol, read from the realm: curl to the realm, curl to its own ClickHouse, and an implicit
# yes from its human.
#
#   REALM_URL=<url> REALM_PREFIX=<prefix> WORK=<private dir> [ADMIN_SQL=<command>] test/e2e.sh
#
# Needs test/members.sh up and demo/up.sh to have run with the same WORK. Without ADMIN_SQL
# the admin-side canary checks are skipped (and reported as skipped).
#
# Proofs:
#   E1  the support member alone reads nothing of the customer's house
#   E2  the full case, opened by the customer, ending with the fix applied and the problem
#       measured as gone
#   E3  the canary never appears in any realm room or the realm's query_log, checked as each
#       member and as admin
#   E4  the customer's own rooms refuse what the protocol forbids (469), and the local account
#       never read a row
#   E5  revoking the grants ends the case: the support member's next INSERT fails with 497
set -uo pipefail
: "${REALM_URL:?}" "${REALM_PREFIX:?}" "${WORK:?}"
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
. "$here/lib.sh"
umask 077

DESK="$root/support/desk"
S=$(awk '$1 == "support" {print $2}' "$WORK/members")
H=$(awk '$1 == "customer" {print $2}' "$WORK/members")    # a member's house bears its name
LOCAL=$(cat "$WORK/local_url")
CANARY=$(cat "$WORK/canary")
half=$(( ${#CANARY} / 2 ))
# The canary is searched for as concat(a, b): a check's own text never holds it whole, so the
# checks cannot plant what they look for in the query_log.
NEEDLE="concat('${CANARY:0:$half}', '${CANARY:$half}')"
HUMAN="Ada Customer"

cat > "$WORK/desk.json" <<EOF
{"realm_url": "$REALM_URL", "realm_curlrc": "$WORK/support.curlrc", "member": "$S"}
EOF
export SUPPORT_DESK_CONFIG="$WORK/desk.json"
mkdir -p "$WORK/c"

as_support()  { q_as "$WORK/support.curlrc" "$REALM_URL" "$@" 2>&1; }
as_customer() { q_as "$WORK/customer.curlrc" "$REALM_URL" "$@" 2>&1; }
local_admin() { q_as "$WORK/local-admin.curlrc" "$LOCAL" "$@" 2>&1; }
jget() { python3 -c 'import json,sys; v=json.loads(sys.stdin.readline() or "{}").get(sys.argv[1], ""); print(json.dumps(v) if isinstance(v, (list, dict)) else v)' "$1"; }
field() { python3 -c 'import json,re,sys; a=json.loads(sys.stdin.read() or "{}"); print(eval(sys.argv[1], {"a": a, "json": json, "re": re}))' "$1"; }

# --- the customer's agent, by the protocol -------------------------------------------------
realm_c() { _curl -K "$WORK/customer.curlrc" "${REALM_URL%/}/" "$@"; }

# phase NAME -- run each statement of that published phase, one per request, <house> replaced
phase() {
  local i=0 out=""
  as_customer "SELECT stmt FROM $S.statements WHERE phase = '$1' ORDER BY step FORMAT JSONEachRow" > "$WORK/c/phase-$1.json"
  while IFS= read -r line; do
    i=$((i + 1))
    printf '%s' "$line" | jget stmt | sed "s/<house>/$H/g" > "$WORK/c/phase-$1-$i.sql"
    out+=$(realm_c --data-binary @"$WORK/c/phase-$1-$i.sql" 2>&1)
  done < "$WORK/c/phase-$1.json"
  echo "${i} statements${out:+; $out}"
}

# send CASE REQ STATUS [FILE] -- one answer, as the human approved it; a FILE goes byte for byte
send() {
  if [ -n "${4:-}" ]; then
    realm_c --url-query "query=INSERT INTO $H.support_answers (case_id, req_id, status, approved_by, payload) SELECT {c:String}, {r:String}, {s:String}, {by:String}, raw FROM input('raw String') FORMAT RawBLOB" \
      --url-query "param_c=$1" --url-query "param_r=$2" --url-query "param_s=$3" --url-query "param_by=$HUMAN" \
      --data-binary @"$4" 2>&1
  else
    realm_c --url-query "query=INSERT INTO $H.support_answers (case_id, req_id, status, approved_by) VALUES ({c:String}, {r:String}, {s:String}, {by:String})" \
      --url-query "param_c=$1" --url-query "param_r=$2" --url-query "param_s=$3" --url-query "param_by=$HUMAN" \
      --data-binary '' 2>&1
  fi
}

# request REQ -- the request row, as one JSON line, from the customer's own room
request() {
  realm_c --url-query "param_r=$1" --data-binary "SELECT req_id, kind, db, tbl, hours, lim, toString(qhash) AS qhash, stmt, text, author
    FROM $H.support_requests WHERE req_id = {r:String} FORMAT JSONEachRow" 2>&1
}

answered() { [ "$(as_customer "SELECT count() FROM $H.support_answers WHERE req_id = '$1'")" != 0 ]; }

# answer REQ -- a diagnostic: check the author, run the customer's own copy of that kind's SQL
# on its own ClickHouse with the typed columns as parameters, send the file on a yes, and
# confirm the server's hash against the file's. Prints the outcome.
answer() {
  local req=$1 row kind f
  row=$(request "$req")
  [ "$(printf '%s' "$row" | jget author)" = "$S" ] || { echo "not from $S"; return 1; }
  answered "$req" && { echo "already answered"; return 0; }
  kind=$(printf '%s' "$row" | jget kind)
  realm_c --data-binary "SELECT sql FROM $H.support_kinds WHERE kind = '$kind' FORMAT RawBLOB" > "$WORK/c/$kind.sql"
  [ -s "$WORK/c/$kind.sql" ] || { send "$CASE" "$req" refused >/dev/null; echo refused; return 0; }
  f="$WORK/c/$req.json"
  if ! _curl -K "$WORK/local-gate.curlrc" "${LOCAL%/}/" \
      --url-query "param_db=$(printf '%s' "$row" | jget db)" --url-query "param_tbl=$(printf '%s' "$row" | jget tbl)" \
      --url-query "param_hours=$(printf '%s' "$row" | jget hours)" --url-query "param_lim=$(printf '%s' "$row" | jget lim)" \
      --url-query "param_qhash=$(printf '%s' "$row" | jget qhash)" --data-binary @"$WORK/c/$kind.sql" > "$f" 2>&1; then
    printf '%s' "$(err_code "$(cat "$f")")" > "$f"; send "$CASE" "$req" failed "$f" >/dev/null; echo failed; return 0
  fi
  send "$CASE" "$req" answered "$f" >/dev/null
  if [ "$(as_customer "SELECT payload_sha256 FROM $H.support_answers WHERE req_id = '$req'")" = \
       "$(shasum -a 256 "$f" | cut -d' ' -f1)" ]; then echo "sent, hash matches"; else echo "hash differs"; fi
}

# apply_fix REQ -- a fix: run the row's stmt exactly, on a yes; send only the outcome
apply_fix() {
  local req=$1 row out
  row=$(request "$req")
  [ "$(printf '%s' "$row" | jget author)" = "$S" ] || { echo "not from $S"; return 1; }
  [ "$(printf '%s' "$row" | jget kind)" = apply ] || { echo "not a fix"; return 1; }
  answered "$req" && { echo "already answered"; return 0; }
  printf '%s' "$row" | jget stmt > "$WORK/c/$req.sql"
  if out=$(_curl -K "$WORK/local-gate.curlrc" "${LOCAL%/}/" --data-binary @"$WORK/c/$req.sql" 2>&1); then
    send "$CASE" "$req" applied >/dev/null; echo applied
  else
    printf '%s' "$(err_code "$out")" > "$WORK/c/$req.code"; send "$CASE" "$req" failed "$WORK/c/$req.code" >/dev/null; echo failed
  fi
}

# desk_answer REQ -- the support member's view of the answer to REQ, as one JSON line
desk_answer() { "$DESK" answers "$H" --req "$1" --json; }

note "realm $REALM_URL; support $S; customer $H; customer ClickHouse $LOCAL"

# --- the support member publishes the protocol --------------------------------------------
pub=$("$root/support/publish" --commit "$(git -C "$root" rev-parse HEAD)" 2>&1)
expect_match "E2 the support member publishes the protocol into its own house" "$pub" "open to __${REALM_PREFIX}_member"
expect_eq "E2 a member who installed nothing reads the protocol from the realm" \
  "$(as_customer "SELECT count() FROM $S.protocol WHERE section IN ('the-rules', 'enroll', 'answer-a-diagnostic', 'end')")" 4

# --- E1: alone, the support member reads nothing ------------------------------------------
as_customer "CREATE TABLE IF NOT EXISTS $H.private_notes (k String, v String) ENGINE = MergeTree ORDER BY k" >/dev/null
as_customer "INSERT INTO $H.private_notes VALUES ('renewal', 'march, 3 seats')" >/dev/null
expect_eq "E1 before enrollment, support cannot read a customer room" \
  "$(err_code "$(as_support "SELECT count() FROM $H.private_notes")")" 497
expect_eq "E1 before enrollment, support cannot write a customer room" \
  "$(err_code "$(as_support "INSERT INTO $H.private_notes VALUES ('x', 'y')")")" 497
expect_match "E1 before enrollment, support's desk lists no customer" "$("$DESK" clients)" "no customer has enrolled you"

expect_eq "E2 the customer enrolls by running the published statements" "$(phase enroll)" "6 statements"
expect_match "E2 the desk discovers the enrollment from its own grants" "$("$DESK" clients)" "^$H	enrolled"
expect_eq "E2 the customer's copy of the SQL matches the published kinds" \
  "$(as_customer "SELECT count() FROM $H.support_kinds AS k INNER JOIN $S.kinds AS p USING (kind) WHERE k.sql = p.sql")" 7
expect_eq "E1 after enrollment, support still cannot read a customer room" \
  "$(err_code "$(as_support "SELECT count() FROM $H.private_notes")")" 497
expect_eq "E1 after enrollment, support cannot read its own requests" \
  "$(err_code "$(as_support "SELECT count() FROM $H.support_requests")")" 497
expect_eq "E1 support cannot read or change the customer's copy of the SQL" \
  "$(err_code "$(as_support "SELECT count() FROM $H.support_kinds")")/$(err_code "$(as_support "INSERT INTO $H.support_kinds (kind, sql) VALUES ('errors', 'SELECT * FROM demo.events')")")" "497/497"
expect_eq "E1 support cannot forge a request's author" \
  "$(err_code "$(as_support "INSERT INTO $H.support_requests (case_id, req_id, kind, author) VALUES ('c-forge', 'r-forge', 'errors', '$H')")")" 44
expect_eq "E1 support cannot write an answer" \
  "$(err_code "$(as_support "INSERT INTO $H.support_answers (case_id, req_id, status, approved_by) VALUES ('c-forge', 'r-forge', 'applied', 'Eve')")")" 497

# --- E4: the customer's rooms refuse what the protocol forbids ------------------------------
ins() { err_code "$(as_support "INSERT INTO $H.support_requests (case_id, req_id, $1) VALUES ('c-refuse', $2)")"; }
expect_eq "E4 the room refuses an unknown kind (free SQL)" "$(ins "kind, text" "'r-k1', 'sql', 'SELECT * FROM demo.events'")" 469
expect_eq "E4 the room refuses a table name that is not an identifier" "$(ins "kind, db, tbl" "'r-k2', 'table_schema', 'demo', 'events WHERE 1'")" 469
expect_eq "E4 the room refuses hours out of range" "$(ins "kind, hours" "'r-k3', 'slow_queries', 5000")" 469
expect_eq "E4 the room refuses a malformed request id" "$(ins "kind" "'r k4!', 'errors'")" 469
expect_eq "E4 the room refuses a DELETE as a fix" "$(ins "kind, stmt" "'r-k5', 'apply', 'ALTER TABLE demo.events DELETE WHERE 1'")" 469
expect_eq "E4 the room refuses a SELECT as a fix" "$(ins "kind, stmt" "'r-k6', 'apply', 'SELECT * FROM demo.accounts'")" 469
expect_eq "E4 the room refuses two statements chained into a fix" "$(ins "kind, stmt" "'r-k7', 'apply', 'OPTIMIZE TABLE demo.events; DROP TABLE demo.events'")" 469
expect_eq "E4 the room refuses a fix on a system table" "$(ins "kind, stmt" "'r-k8', 'apply', 'OPTIMIZE TABLE system.query_log'")" 469
expect_eq "E4 the room refuses a statement on any kind but apply" "$(ins "kind, stmt, text" "'r-k9', 'note', 'OPTIMIZE TABLE demo.events', 'x'")" 469
expect_eq "E4 the answers room refuses a refusal that carries a payload" \
  "$(err_code "$(as_customer "INSERT INTO $H.support_answers (case_id, req_id, status, approved_by, payload) VALUES ('c-refuse', 'r-k1', 'refused', 'Ada', 'some text')")")" 469
expect_eq "E4 the answers room refuses a failure that carries more than a code" \
  "$(err_code "$(as_customer "INSERT INTO $H.support_answers (case_id, req_id, status, approved_by, payload) VALUES ('c-refuse', 'r-k1', 'failed', 'Ada', 'Cannot parse x')")")" 469
expect_eq "E4 the answers room refuses an approver that is not a name" \
  "$(err_code "$(as_customer "INSERT INTO $H.support_answers (case_id, req_id, status, approved_by) VALUES ('c-refuse', 'r-k1', 'denied', 'x9f3a7c1e5b2')")")" 469

# --- E2: the case -----------------------------------------------------------------------
RUN=$(openssl rand -hex 4)     # this run's workload tags: an earlier run's lookups never count
WORK="$WORK" "$root/demo/workload.sh" "before-$RUN"
before=$(local_admin "SELECT round(avg(read_rows)) FROM system.query_log WHERE type = 'QueryFinish'
  AND log_comment = 'before-$RUN' AND query LIKE '%WHERE user_id = %'")
expect_ge "E2 before the fix, a lookup by user reads most of the table" "$before" 5000000

CASE="c$(date +%Y%m%d)-$(openssl rand -hex 3)"
printf 'Our dashboards that look up events by user_id got slow: each takes about a second. The table is demo.events.\n' > "$WORK/c/problem.txt"
send "$CASE" open opened "$WORK/c/problem.txt" >/dev/null
expect_match "E2 the customer opens the case; the desk sees it as its move" "$("$DESK" tick --cadence 60)" "$H $CASE: your move"
expect_eq "E2 the heartbeat is readable by any member" \
  "$(as_customer "SELECT cadence_s FROM $S.heartbeat ORDER BY at DESC LIMIT 1")" 60

r=$("$DESK" ask "$H" "$CASE" slow_queries hours=1 lim=10)
expect_eq "E2 slow_queries: the customer runs its copy; the server's hash matches the file it showed" "$(answer "$r")" "sent, hash matches"
SQ=$(desk_answer "$r")
expect_eq "E2 slow_queries is answered, verified, with the human's name on it" \
  "$(printf '%s' "$SQ" | field 'a["status"] + "/" + a["approved_by"] + "/" + str(a["verified"])')" "answered/$HUMAN/True"
SHAPE=$(printf '%s' "$SQ" | field 'json.dumps([x for x in [json.loads(l) for l in a["payload"].splitlines()] if "user_id" in x["query_shape"]][0])')
HASH=$(printf '%s' "$SHAPE" | jget qhash)
expect_match "E2 support sees the slow query's shape, without its values" "$(printf '%s' "$SHAPE" | jget query_shape)" "WHERE user_id = \?$"
expect_ge "E2 support sees how many rows a lookup reads" "$(printf '%s' "$SHAPE" | jget avg_read_rows)" 5000000

r=$("$DESK" ask "$H" "$CASE" table_schema db=demo tbl=events)
answer "$r" >/dev/null
expect_eq "E2 support sees the table's sorting key" "$(desk_answer "$r" | field 'json.loads(a["payload"])["sorting_key"]')" event_time

r=$("$DESK" ask "$H" "$CASE" query_profile "qhash=$HASH" hours=1)
answer "$r" >/dev/null
# averaged over the window, so an earlier run's lookups in the same hour may lower it
expect_eq "E2 support sees that the lookup selects most marks of the table" \
  "$(desk_answer "$r" | field '2 * json.loads(a["payload"])["marks_selected"] >= json.loads(a["payload"])["marks_total"] > 0')" True

r=$("$DESK" ask "$H" "$CASE" errors)
answer "$r" >/dev/null
expect_match "E2 errors are answered, the parse error cut at its literal" \
  "$(desk_answer "$r" | field '[json.loads(l)["message"] for l in a["payload"].splitlines() if json.loads(l)["name"] == "CANNOT_PARSE_TEXT"][0]')" "^Cannot parse string \?$"

for k in server_info tables_overview parts_health; do
  r=$("$DESK" ask "$H" "$CASE" "$k"); answer "$r" >/dev/null
  expect_eq "E2 $k is answered" "$(desk_answer "$r" | field 'a["status"] + "/" + str(a["verified"])')" "answered/True"
done

r=$("$DESK" note "$H" "$CASE" "demo.events is sorted by event_time, but the dashboards filter by user_id, so each lookup reads all 10M rows. A projection sorted by user_id lets ClickHouse read a few granules instead; it costs one more sorted copy of the table on disk.")
send "$CASE" "$r" acknowledged >/dev/null
expect_eq "E2 the customer acknowledges support's diagnosis" "$(desk_answer "$r" | field 'a["status"]')" acknowledged

r_add=$("$DESK" fix "$H" "$CASE" --stmt "ALTER TABLE demo.events ADD PROJECTION by_user (SELECT * ORDER BY user_id)" --why "lookups by user_id stop scanning the table")
r_mat=$("$DESK" fix "$H" "$CASE" --stmt "ALTER TABLE demo.events MATERIALIZE PROJECTION by_user" --why "build the projection for the rows already there")
expect_no_match "E2 nothing changed before the customer's yes" "$(local_admin "SHOW CREATE TABLE demo.events")" "by_user"
expect_eq "E2 the customer applies the fix with its support-only account" "$(apply_fix "$r_add")/$(apply_fix "$r_mat")" "applied/applied"
expect_eq "E2 a fix that already has an answer is not run again" "$(apply_fix "$r_mat")" "already answered"
expect_eq "E2 support sees only the outcome" "$(desk_answer "$r_mat" | field 'a["status"] + "/" + a["payload"]')" "applied/"
for _ in $(seq 1 60); do
  [ "$(local_admin "SELECT count() FROM system.mutations WHERE table = 'events' AND NOT is_done")" = 0 ] && break; sleep 2
done

WORK="$WORK" "$root/demo/workload.sh" "after-$RUN"
after=$(local_admin "SELECT round(avg(read_rows)) FROM system.query_log WHERE type = 'QueryFinish'
  AND log_comment = 'after-$RUN' AND query LIKE '%WHERE user_id = %'")
if _is_uint "$after"; then after100=$((after * 100)); else after100="$after"; fi
expect_lt "E2 after the fix, a lookup by user reads under 1% of what it did" "$after100" "$before"
note "rows read per lookup: $before before the fix, $after after"

r=$("$DESK" close "$H" "$CASE" --why "lookups by user read a few granules now")
send "$CASE" "$r" acknowledged >/dev/null
expect_match "E2 the case is closed on both sides" "$("$DESK" case "$H" "$CASE" | head -1)" ": closed$"

# --- E4: the local account never read a row -------------------------------------------------
local_admin "SYSTEM FLUSH LOGS" >/dev/null
expect_eq "E4 the customer's support account never read a row of a user table" \
  "$(local_admin "SELECT count() FROM system.query_log WHERE user = 'support_gate' AND query_kind = 'Select'
      AND type = 'QueryFinish' AND NOT has(databases, 'system') AND length(databases) > 0")" 0
expect_eq "E4 ... and when it tries, ClickHouse refuses it (497)" \
  "$(err_code "$(q_as "$WORK/local-gate.curlrc" "$LOCAL" "SELECT email FROM demo.accounts LIMIT 1" 2>&1)")" 497
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
expect_ge "E3 control: the search finds a string that is there (the case id)" \
  "$(as_customer "SELECT countIf(position(formatRow('TSV', *), '$CASE') > 0) FROM $H.support_answers")" 1
expect_eq "E3 as the customer: no room in its house holds the canary" \
  "$(rooms_hits "$WORK/customer.curlrc" "$H" support_requests support_answers support_kinds private_notes)" 0
expect_eq "E3 as support: no room it can read holds the canary" \
  "$(rooms_hits "$WORK/support.curlrc" "$H" support_answers)/$(rooms_hits "$WORK/support.curlrc" "$S" sent heartbeat protocol kinds statements)" "0/0"
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
    "$(admin "SELECT count() FROM system.query_log WHERE event_date >= today() - 1 AND position(query, '$CASE') > 0")" 1
  expect_eq "E3 as admin: no query, and no error, in the realm's query_log holds the canary" \
    "$(admin "SELECT count() FROM system.query_log WHERE event_date >= today() - 1
              AND (position(query, $NEEDLE) > 0 OR position(exception, $NEEDLE) > 0)")" 0
else
  skip "E3 as admin (ADMIN_SQL is not set)"
fi

# --- E5: revoking ends the case ---------------------------------------------------------
expect_eq "E5 the customer ends the case with the published end statements" "$(phase end)" "2 statements"
expect_eq "E5 support's next request fails with 497" \
  "$(err_code "$(as_support "INSERT INTO $H.support_requests (case_id, req_id, kind) VALUES ('$CASE', 'r-after-end', 'slow_queries')")")" 497
expect_eq "E5 support can no longer read the answers" \
  "$(err_code "$(as_support "SELECT count() FROM $H.support_answers")")" 497
expect_match "E5 the desk no longer lists the customer" "$("$DESK" clients)" "no customer has enrolled you"

finish
