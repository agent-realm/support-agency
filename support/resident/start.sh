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
python3 - "$CLAUDE_CONFIG_DIR" "$run" "$run/settings.json" <<'PY' || exit 1
import json, os, sys
cfg, run, ours = sys.argv[1], os.path.realpath(sys.argv[2]), json.load(open(sys.argv[3]))["permissions"]
denied = set(ours["deny"]) | set(ours["allow"])
extra = []
def load(path):
    try:   # fail closed: a file this cannot read may still grant something to Claude Code
        return json.load(open(path))
    except Exception as e:
        print(f"start: cannot check {path} ({e}); refusing to start", file=sys.stderr)
        sys.exit(1)
# every settings file Claude Code may merge for this run: the config dir's, and the run dir's
for path in (os.path.join(cfg, "settings.json"), os.path.join(cfg, "settings.local.json"),
             os.path.join(run, ".claude", "settings.json"), os.path.join(run, ".claude", "settings.local.json")):
    if os.path.exists(path):
        d = load(path)
        rules = d.get("permissions", {}).get("allow", []) + d.get("allowedTools", [])
        extra += [f"{path}: {r}" for r in rules if r not in denied]
# approvals remembered per project in the config dir's .claude.json
path = os.path.join(cfg, ".claude.json")
if os.path.exists(path):
    for proj, p in load(path).get("projects", {}).items():
        if os.path.realpath(proj) == run:
            rules = dict.fromkeys(p.get("allowedTools", []) + p.get("approvedTools", []))
            extra += [f"{path} ({proj}): {r}" for r in rules if r not in denied]
if extra:
    print("start: Claude Code would allow more than ./desk here; deny or remove these first:", *extra, sep="\n  ", file=sys.stderr)
    sys.exit(1)
PY
exec claude --safe-mode --model "${RESIDENT_MODEL:-claude-sonnet-5-5}" --settings "$run/settings.json" --permission-mode dontAsk \
  --append-system-prompt-file "$run/RESIDENT.md"
