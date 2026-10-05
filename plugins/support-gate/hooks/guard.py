#!/usr/bin/env python3
"""PreToolUse guard for the support gate.

Support's requests are text written by someone outside the company, and the agent reads them.
If that text talks the agent into reaching the customer's ClickHouse, or the answer room,
some other way, this hook stops the tool call. It denies:
  - a Read of either credentials file named in the gate's config;
  - a Bash command that mentions a credentials file, the local ClickHouse address, or a case
    room, unless the whole command is one plain call of the gate.
It is a guard rail, not the boundary: the gate's allowlist is the boundary, and the customer
should keep Claude Code's permission prompts on for `gate send`.
"""
import json, os, re, shlex, sys

def main():
    try:
        event = json.load(sys.stdin)
    except ValueError:
        return
    path = os.path.expanduser(os.environ.get("SUPPORT_GATE_CONFIG", "~/.support-gate/config.json"))
    try:
        with open(path) as f:
            cfg = json.load(f)
    except (OSError, ValueError):
        return                                  # no gate configured: nothing to guard
    secrets = [os.path.expanduser(cfg[k]) for k in ("realm_curlrc", "local_curlrc") if cfg.get(k)]
    local = re.sub(r"^https?://", "", cfg.get("local_url", "")).rstrip("/")
    tool, inp = event.get("tool_name"), event.get("tool_input") or {}

    if tool == "Read":
        target = os.path.realpath(os.path.expanduser(inp.get("file_path", "")))
        if target in (os.path.realpath(s) for s in secrets):
            deny("that file holds a credential the gate uses; nothing reads it but the gate")
        return
    if tool != "Bash":
        return
    cmd = inp.get("command", "")
    needles = secrets + [os.path.basename(s) for s in secrets] + ["support_answers", "support_requests"]
    if local:
        needles.append(local)
    if not any(n and n in cmd for n in needles):
        return
    try:
        words = shlex.split(cmd)
    except ValueError:
        words = []
    plain = words and not re.search(r"[;&|`$<>\n]", cmd)
    if plain and words[0] in ("python3", "python") and len(words) > 1:
        words = words[1:]
    if plain and os.path.basename(words[0]) == "gate":
        return
    deny("this command reaches the customer's ClickHouse or the case rooms outside the gate; "
         "use the gate's own commands")


def deny(reason):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                             "permissionDecision": "deny",
                                             "permissionDecisionReason": "support-gate: " + reason}}))
    sys.exit(0)


if __name__ == "__main__":
    main()
