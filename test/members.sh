#!/usr/bin/env bash
# test/members.sh up|down -- two throwaway realm members for the end-to-end test: one for the
# support team and one for the customer, made the way any newcomer joins (knock, then claim).
#
#   REALM_URL=<url> REALM_PREFIX=<prefix> WORK=<private dir> test/members.sh up
#   ... ADMIN_SQL=<command> test/members.sh down
#
# up writes $WORK/support.curlrc and $WORK/customer.curlrc (mode 600) and $WORK/members
# (role, then member name, one per line). down drops both members and their houses through
# ADMIN_SQL: a command that runs one statement, read from stdin, as the realm's admin.
set -euo pipefail
: "${REALM_URL:?}" "${REALM_PREFIX:?}" "${WORK:?}"
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"
umask 077

guest() { _curl "${REALM_URL%/}/?user=${REALM_PREFIX}_guest" --data-binary @-; }
sha() { printf %s "$1" | shasum -a 256 | cut -d' ' -f1; }

join() {   # join ROLE HANDLE
  local role=$1 h=$2 pw tok st=""
  pw=$(openssl rand -hex 16); tok=$(openssl rand -hex 16)
  printf "INSERT INTO %s_lobby.register (handle, pw_digest, token_hash) VALUES ('%s', '%s', '%s')" \
    "$REALM_PREFIX" "$h" "$(sha "$pw")" "$(sha "$tok")" | guest
  for _ in $(seq 1 30); do
    st=$(printf "SELECT status FROM %s_lobby.claim(token = '%s') FORMAT TSV" "$REALM_PREFIX" "$tok" | guest)
    [ "$st" = accepted ] && break
    sleep 1
  done
  [ "$st" = accepted ] || { echo "members: $h was not admitted (status '$st')" >&2; return 1; }
  printf 'user = "%s_%s:%s"\n' "$REALM_PREFIX" "$h" "$pw" > "$WORK/$role.curlrc"
  printf '%s %s_%s\n' "$role" "$REALM_PREFIX" "$h" >> "$WORK/members"
}

case "${1:-}" in
  up)
    : > "$WORK/members"
    join support "tsupp$(openssl rand -hex 3)"
    join customer "tcust$(openssl rand -hex 3)"
    cat "$WORK/members" ;;
  down)
    : "${ADMIN_SQL:?ADMIN_SQL must name the realm admin command}"
    while read -r role member; do
      printf 'DROP USER IF EXISTS %s' "$member" | $ADMIN_SQL
      printf 'DROP DATABASE IF EXISTS %s' "$member" | $ADMIN_SQL
      echo "dropped $role $member"
    done < "$WORK/members" ;;
  *) echo "usage: test/members.sh up|down" >&2; exit 3 ;;
esac
