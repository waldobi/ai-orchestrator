#!/bin/bash
# Try AI Orchestrator with made-up data: no sign-in, nothing real read or changed.
#   scripts/demo.sh          build and run the demo
#   scripts/demo.sh stop     quit it and remove its settings
# It runs as a separate app (bundle id local.ai-orchestrator.demo) with a throwaway home folder, so it can't
# see your Claude, Codex or Cursor data, and it never starts at login or runs agents.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="${TMPDIR:-/tmp}"; DEMO_HOME="${AIO_DEMO_HOME:-${TMP%/}/aio-demo-home}"
APP="$DEMO_HOME/AI Orchestrator Demo.app"

if [[ "${1:-}" == "stop" ]]; then
  pkill -f "AI Orchestrator Demo.app/Contents/MacOS/AIOrchestrator" 2>/dev/null || true
  defaults delete local.ai-orchestrator.demo >/dev/null 2>&1 || true   # the demo's own settings
  exit 0
fi

mkdir -p "$DEMO_HOME/Library/Application Support/Claude" \
         "$DEMO_HOME/Library/Application Support/Claude-work" \
         "$DEMO_HOME/Library/Application Support/Claude-side" \
         "$APP/Contents/MacOS"

echo "Building the demo (a few minutes)…"
swiftc -O -parse-as-library -target "$(uname -m)-apple-macos14.0" -o "$APP/Contents/MacOS/AIOrchestrator" \
  AIOrchestrator.swift Orchestrator.swift T3.swift Board.swift Hub.swift OneWindow.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>AI Orchestrator Demo</string>
  <key>CFBundleIdentifier</key><string>local.ai-orchestrator.demo</string>
  <key>CFBundleExecutable</key><string>AIOrchestrator</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

# Friendly names for the made-up accounts, and the desktop strip switched on.
defaults write local.ai-orchestrator.demo name.work "Work"
defaults write local.ai-orchestrator.demo name.side "Side project"
defaults write local.ai-orchestrator.demo desktopStrip -bool true

AIO_DEMO=1 CFFIXED_USER_HOME="$DEMO_HOME" HOME="$DEMO_HOME" "$APP/Contents/MacOS/AIOrchestrator" >/dev/null 2>&1 &
echo "Demo running (pid $!). Quit it from its menu, or run: scripts/demo.sh stop"
