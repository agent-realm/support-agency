#!/usr/bin/env bash
# support/resident/start.sh -- set up the resident support agent's run directory and start it.
#
#   REALM_URL=<url> REALM_PREFIX=<prefix> support/resident/start.sh [run dir]
#
# The run directory (default ~/.support-resident) holds a copy of desk, RESIDENT.md, the
# permission settings and the desk config; the credential stays in ~/.<prefix>/support.curlrc.
# The agent runs with Claude Code's customizations off (--safe-mode), in dontAsk mode, allowed
# exactly one command: ./desk. A customer's words reach it as data; even if they talk it into
# something, the only thing it can do is run desk, and desk can only write requests.
#
# RESIDENT_CLAUDE_CONFIG_DIR picks the Claude Code config dir (its login) to run under. Safe mode
# drops its CLAUDE.md, hooks, skills and plugins, but its settings' allow rules still merge with
# ours: settings.json denies the ones known on the pilot's installs; check yours.
# RESIDENT_MODEL picks the model (default claude-sonnet-5-5).
set -euo pipefail
: "${REALM_URL:?}" "${REALM_PREFIX:?}"
here=$(cd "$(dirname "$0")" && pwd)
run=${1:-$HOME/.support-resident}
rc="$HOME/.$REALM_PREFIX/support.curlrc"
[ -f "$rc" ] || { echo "start: no $rc; run join.sh first" >&2; exit 1; }
mkdir -p "$run"; chmod 700 "$run"
cp "$here/../desk" "$run/desk"; chmod 700 "$run/desk"
sed "s/<prefix>/$REALM_PREFIX/g" "$here/RESIDENT.md" > "$run/RESIDENT.md"
cp "$here/settings.json" "$run/"
printf '{"realm_url": "%s", "realm_curlrc": "%s", "member": "%s_support"}\n' "$REALM_URL" "$rc" "$REALM_PREFIX" > "$run/desk.json"
cd "$run"
export SUPPORT_DESK_CONFIG="$run/desk.json"
export CLAUDE_CONFIG_DIR="${RESIDENT_CLAUDE_CONFIG_DIR:-$HOME/.claude}"
# The config dir's allow rules merge with ours. Refuse to start if it allows anything that
# settings.json does not deny: the resident must be able to run ./desk and nothing else.
python3 - "$CLAUDE_CONFIG_DIR" "$run/settings.json" <<'PY' || exit 1
import json, os, sys
cfg, ours = sys.argv[1], json.load(open(sys.argv[2]))["permissions"]
denied = set(ours["deny"]) | set(ours["allow"])
extra = []
for f in ("settings.json", "settings.local.json"):
    try:
        allow = json.load(open(os.path.join(cfg, f))).get("permissions", {}).get("allow", [])
    except (OSError, ValueError):
        continue
    extra += [f"{f}: {r}" for r in allow if r not in denied]
if extra:
    print("start: the config dir allows more than ./desk; deny these in settings.json first:", *extra, sep="\n  ", file=sys.stderr)
    sys.exit(1)
PY
exec claude --safe-mode --model "${RESIDENT_MODEL:-claude-sonnet-5-5}" --settings "$run/settings.json" --permission-mode dontAsk \
  --append-system-prompt-file "$run/RESIDENT.md" "${@:2}"
