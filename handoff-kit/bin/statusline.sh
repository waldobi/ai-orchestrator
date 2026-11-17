#!/bin/bash
# Claude handoff kit: status line wrapper.
# Saves this session's plan usage (rate_limits) so the Stop hook can see it,
# then hands the same input to your previous status line, if you had one.
# Usage in settings.json: "$HOME/.handoff-kit/bin/statusline.sh" "<this account's config dir>"
CFG="${1:-$HOME/.claude}"
INPUT="$(cat)"
DIR="$HOME/.handoff-kit/usage"
mkdir -p "$DIR"
printf '%s' "$INPUT" | /usr/bin/python3 -c '
import json, sys, os, time
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
rl = d.get("rate_limits") or {}
sid = d.get("session_id")
if not sid or not rl:
    sys.exit(0)
out = {"session_id": sid, "config_dir": sys.argv[2], "saved_at": int(time.time())}
for k in ("five_hour", "seven_day"):
    w = rl.get(k) or {}
    if "used_percentage" in w:
        out[k] = {"used_percentage": w["used_percentage"], "resets_at": w.get("resets_at")}
p = os.path.join(sys.argv[1], sid + ".json")
tmp = p + ".tmp"
with open(tmp, "w") as f:
    json.dump(out, f)
os.replace(tmp, p)
' "$DIR" "$CFG" 2>/dev/null
# Prune this kit's own usage files after a week.
find "$DIR" -name '*.json' -mtime +7 -delete 2>/dev/null
# Chain to the status line you had before, if any.
if [ -x "$CFG/statusline-previous.sh" ]; then
  printf '%s' "$INPUT" | "$CFG/statusline-previous.sh"
fi
