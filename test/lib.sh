#!/usr/bin/env bash
# Test helpers for the support agency. Source it, run checks, end with `finish` once, in the
# main shell. Output is TAP-shaped: "ok N - name" / "not ok N - name", "#"-prefixed detail,
# then "# N tests, F failed". Bash 3.2 compatible (the macOS system bash).
#
# Never pass a secret or the canary as a checked value or a pattern: a failure prints both.

if [ -z "${_T_FILE:-}" ] || [ ! -f "$_T_FILE" ]; then _T_FILE="$(mktemp "${TMPDIR:-/tmp}/support-test.XXXXXX")"; fi
if [ -z "$(trap -p EXIT)" ]; then trap 'rm -f "$_T_FILE"' EXIT; fi

_t_count() { wc -l < "$_T_FILE" | tr -d ' '; }
ok() { echo pass >> "$_T_FILE"; printf 'ok %d - %s\n' "$(_t_count)" "$1"; }
not_ok() {
  echo fail >> "$_T_FILE"; printf 'not ok %d - %s\n' "$(_t_count)" "$1"
  if [ -n "${2:-}" ]; then printf '%s\n' "${2:0:2000}" | sed 's/^/#   /'; fi
  return 0
}
skip() { printf '# skip - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1" "got '$2', want '$3'"; fi; }

_is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le 18 ]; }
# expect_lt NAME GOT LIMIT -- non-negative integers; GOT < LIMIT
expect_lt() {
  if ! _is_uint "$2" || ! _is_uint "$3"; then not_ok "$1" "got '$2', limit '$3': want integers"; return 0; fi
  if [ "$((10#$2))" -lt "$((10#$3))" ]; then ok "$1"; else not_ok "$1" "got $2, want < $3"; fi
}
expect_ge() {
  if ! _is_uint "$2" || ! _is_uint "$3"; then not_ok "$1" "got '$2', min '$3': want integers"; return 0; fi
  if [ "$((10#$2))" -ge "$((10#$3))" ]; then ok "$1"; else not_ok "$1" "got $2, want >= $3"; fi
}
# expect_match NAME GOT ERE -- an empty GOT fails
expect_match() {
  if [ -z "$2" ]; then not_ok "$1" "got nothing, want /$3/"; return 0; fi
  if [[ "$2" =~ $3 ]]; then ok "$1"; else not_ok "$1" "does not match /$3/:"$'\n'"$2"; fi
}
# expect_no_match NAME GOT ERE -- an empty GOT fails too: absence of evidence is not a pass
expect_no_match() {
  if [ -z "$2" ]; then not_ok "$1" "got nothing, want text without /$3/"; return 0; fi
  if [[ "$2" =~ $3 ]]; then not_ok "$1" "matches /$3/:"$'\n'"$2"; else ok "$1"; fi
}

finish() {
  local n f
  n=$(_t_count); f=$(grep -c '^fail$' "$_T_FILE" || true)
  rm -f "$_T_FILE"
  printf '# %d tests, %d failed\n' "$n" "$f"
  if [ "$n" -eq 0 ]; then echo "# no checks ran"; exit 1; fi
  [ "$f" -eq 0 ]
  exit $?
}

# Every curl: -q first (ignore ~/.curlrc), bounded in time, credentials from a curl config
# file (-K), SQL on stdin -- never in argv.
_curl() { curl -q -sS --fail-with-body --connect-timeout 10 --max-time "${MAX_TIME:-120}" "$@"; }

# q_as CURLRC URL [SQL] -- one statement (SQL as an argument, or stdin) as the user in CURLRC.
# URL may carry a query string (settings such as log_comment).
q_as() {
  local rc="$1" url="$2"; shift 2
  case "$url" in *\?*) ;; *) url="${url%/}/" ;; esac
  if [ $# -gt 0 ]; then printf '%s' "$1" | _curl -K "$rc" "$url" --data-binary @-
  else _curl -K "$rc" "$url" --data-binary @-; fi
}

# err_code TEXT -- the ClickHouse error code in a refusal ("Code: 497. ..."), or "none"
err_code() { local c; c=$(printf '%s' "$1" | sed -n 's/.*Code: \([0-9][0-9]*\)\..*/\1/p' | head -1); echo "${c:-none}"; }
