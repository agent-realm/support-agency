#!/usr/bin/env bash
# support/resident/join.sh -- make the resident's member the way any newcomer joins: knock, then
# claim (the lobby's joining section). Writes ~/.<prefix>/<handle>.curlrc (mode 600, in a mode
# 700 directory) and never prints the password. Refuses to overwrite a working credential.
#
#   REALM_URL=<url> REALM_PREFIX=<prefix> support/resident/join.sh [handle]   (default: support)
set -euo pipefail
: "${REALM_URL:?}" "${REALM_PREFIX:?}"
h=${1:-support}
dir="$HOME/.$REALM_PREFIX"; rc="$dir/$h.curlrc"
umask 077
mkdir -p "$dir"; chmod 700 "$dir"
[ -e "$rc" ] && { echo "join: $rc exists; it is a working credential, not overwritten" >&2; exit 1; }
guest() { curl -q -sS --fail-with-body -A support-resident "${REALM_URL%/}/?user=${REALM_PREFIX}_guest" --data-binary @-; }
sha() { printf %s "$1" | shasum -a 256 | cut -d' ' -f1; }
pw=$(openssl rand -hex 16); tok=$(openssl rand -hex 16)
printf 'user = "%s_%s:%s"\n' "$REALM_PREFIX" "$h" "$pw" > "$rc.new"
printf "INSERT INTO %s_lobby.register (handle, pw_digest, token_hash) VALUES ('%s', '%s', '%s')" \
  "$REALM_PREFIX" "$h" "$(sha "$pw")" "$(sha "$tok")" | guest
unset pw
st=""
for _ in $(seq 1 30); do
  st=$(printf "SELECT status FROM %s_lobby.claim(token = '%s') FORMAT TSV" "$REALM_PREFIX" "$tok" | guest)
  [ "$st" = accepted ] && break
  [ "$st" = rejected ] && break
  sleep 2
done
if [ "$st" != accepted ]; then rm -f "$rc.new"; echo "join: $h not admitted (status '$st')" >&2; exit 1; fi
mv "$rc.new" "$rc"
# accepted can still mean the handle was taken (the realm keeps the existing account): log in
if ! curl -q -sS --fail -A support-resident -K "$rc" "${REALM_URL%/}/" --data-binary 'SELECT currentUser()' >/dev/null 2>&1; then
  rm -f "$rc"; echo "join: login as ${REALM_PREFIX}_$h failed; the handle is probably taken" >&2; exit 1
fi
echo "joined as ${REALM_PREFIX}_$h; credential in $rc"
