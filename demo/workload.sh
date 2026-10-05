#!/usr/bin/env bash
# demo/workload.sh TAG -- the demo customer's dashboards: 20 lookups by user_id, tagged with
# log_comment TAG, so a later read of the local query_log can measure them. With a TAG that
# starts with "before" it also runs the three canary queries (see demo/up.sh).
set -euo pipefail
: "${WORK:?}"
tag=${1:?usage: demo/workload.sh TAG}
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../test/lib.sh"
url=$(cat "$WORK/local_url")
# The query condition cache would make a repeated lookup cheaper by itself, and hide whether
# the fix did anything; the measurement runs without it.
q() { q_as "$WORK/local-admin.curlrc" "$url/?log_comment=$tag&use_query_condition_cache=0" "$@"; }

for i in $(seq 1 20); do
  q "SELECT count(), sum(amount) FROM demo.events WHERE user_id = $((1000000 + i * 7919 % 200000))" >/dev/null
done
if [ "${tag#before}" != "$tag" ]; then
  canary=$(cat "$WORK/canary")
  q "SELECT plan FROM demo.accounts WHERE email = '$canary@example.com'" >/dev/null
  q "SELECT count() FROM demo.events WHERE note = '$canary'" >/dev/null
  q "SELECT toUInt64('$canary')" >/dev/null 2>&1 || true
fi
q_as "$WORK/local-admin.curlrc" "$url" "SYSTEM FLUSH LOGS"
