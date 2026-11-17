#!/bin/bash
# Handoff kit installer: /handoff, /pickup and /handoff-all for Claude Code, plus the hooks that
# show a branch's handoff note when a session starts and ask for one when an account nears its limit.
#
# Safe to run again. It backs up settings.json before changing it, only adds its own hooks,
# and leaves an existing status line alone.
set -euo pipefail
cd "$(dirname "$0")"

CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
KIT="$HOME/.handoff-kit"

mkdir -p "$CFG/commands" "$CFG/skills/session-handoff" "$KIT/bin" "$KIT/state" "$KIT/usage"

copy() {  # copy src dst, keeping a backup if a different file is already there
  if [[ -f "$2" ]] && ! cmp -s "$1" "$2"; then cp "$2" "$2.bak-$(date +%Y%m%d%H%M%S)"; fi
  cp "$1" "$2"
}
for c in handoff pickup handoff-all; do copy "commands/$c.md" "$CFG/commands/$c.md"; done
copy skills/session-handoff/SKILL.md "$CFG/skills/session-handoff/SKILL.md"
copy bin/handoff-hook.py "$KIT/bin/handoff-hook.py"
copy bin/statusline.sh "$KIT/bin/statusline.sh"
chmod +x "$KIT/bin/handoff-hook.py" "$KIT/bin/statusline.sh"

/usr/bin/python3 - "$CFG/settings.json" "$CFG" <<'PY'
import json, os, shutil, sys, time
path, cfg = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)
    shutil.copy(path, f"{path}.bak-{time.strftime('%Y%m%d%H%M%S')}")
hooks = data.setdefault("hooks", {})
for event, arg in (("SessionStart", "session-start"), ("Stop", "stop")):
    cmd = f'/usr/bin/python3 "$HOME/.handoff-kit/bin/handoff-hook.py" {arg}'
    groups = hooks.setdefault(event, [])
    if not any(h.get("command") == cmd for g in groups for h in g.get("hooks", [])):
        groups.append({"hooks": [{"type": "command", "command": cmd}]})
ours = f'"$HOME/.handoff-kit/bin/statusline.sh" "{cfg}"'
if "statusLine" not in data:
    data["statusLine"] = {"type": "command", "command": ours}
elif data["statusLine"].get("command") != ours:
    print("  You already have a status line, so it was left alone. The limit warning needs the kit's")
    print(f"  status line: save your current one as {cfg}/statusline-previous.sh (the kit calls it),")
    print(f"  then set statusLine.command to: {ours}")
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY

echo "  ✓ Handoff kit installed for $CFG"
echo "    Commands: /handoff, /pickup, /handoff-all. Restart Claude Code to load them."
echo "    For another Claude login, run again with CLAUDE_CONFIG_DIR=~/.claude-<name>."
