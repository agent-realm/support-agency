#!/usr/bin/env bash
# demo/up.sh -- start the demo customer's own ClickHouse in a lab, and seed it with synthetic
# data that has one diagnosable problem and a canary.
#
#   WORK=<private dir> demo/up.sh        (lab name: $DEMO_LAB, default support-demo)
#
# Writes into $WORK (mode 600): local_url, local-admin.curlrc, local-gate.curlrc, canary.
#
# The problem: demo.events (10M rows) is ordered by event_time, while the workload filters
# by user_id, so every lookup reads the whole table.
#
# The canary: a random string that the customer holds and the realm must never see. It sits
# in rows of two user tables, and in the literals of three customer queries: a lookup by
# e-mail address, one that scans, and one that fails, so it reaches an error message too.
set -euo pipefail
: "${WORK:?WORK must name a private scratch directory}"
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../test/lib.sh"
name=${DEMO_LAB:-support-demo}
umask 077

sha() { printf %s "$1" | shasum -a 256 | cut -d' ' -f1; }
admin_pw=$(openssl rand -hex 16); gate_pw=$(openssl rand -hex 16)
sed -e "s/__ADMIN_SHA256__/$(sha "$admin_pw")/" -e "s/__GATE_SHA256__/$(sha "$gate_pw")/" \
  "$here/customer.yml" > "$WORK/customer.yml"
printf 'user = "customer:%s"\n' "$admin_pw" > "$WORK/local-admin.curlrc"
printf 'user = "support_gate:%s"\n' "$gate_pw" > "$WORK/local-gate.curlrc"
unset admin_pw gate_pw

lab up "$name" --compose "$WORK/customer.yml"
port=$(lab env "$name" | sed -n 's/.*PORT_BASE=\([0-9][0-9]*\).*/\1/p')
[ -n "$port" ] || { echo "demo: no PORT_BASE for lab $name" >&2; exit 1; }
url="http://localhost:$port"
printf '%s\n' "$url" > "$WORK/local_url"

q() { q_as "$WORK/local-admin.curlrc" "$url" "$@"; }
for _ in $(seq 1 90); do [ "$(q 'SELECT 1' 2>/dev/null)" = 1 ] && break; sleep 2; done
[ "$(q 'SELECT 1')" = 1 ] || { echo "demo: $url never answered" >&2; exit 1; }

canary="CANARY-$(openssl rand -hex 8)"
printf '%s' "$canary" > "$WORK/canary"

q "CREATE DATABASE IF NOT EXISTS demo"
q "CREATE TABLE demo.events (event_time DateTime, user_id UInt64, amount Decimal(18, 2), note String)
   ENGINE = MergeTree ORDER BY event_time"
q "INSERT INTO demo.events
   SELECT toDateTime('2026-09-01 00:00:00') + intDiv(number, 4), 1000000 + cityHash64(number) % 200000,
          (number % 10000) / 100, if(number % 1000003 = 0, '$canary', concat('order ', toString(number % 977)))
   FROM numbers(10000000)"
q "CREATE TABLE demo.accounts (email String, user_id UInt64, plan LowCardinality(String))
   ENGINE = MergeTree ORDER BY email"
q "INSERT INTO demo.accounts SELECT concat('user', toString(number), '@example.net'), 1000000 + number,
   ['free', 'pro', 'team'][number % 3 + 1] FROM numbers(200000)"
q "INSERT INTO demo.accounts VALUES ('$canary@example.com', 1199999, 'pro')"
note "demo customer up: $url, lab $name; $(q 'SELECT count() FROM demo.events') events"
