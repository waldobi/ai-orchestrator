#!/bin/bash
# ------------------------------------------------------------------
# AI Orchestrator installer. Double-click to run, or run ./install.command.
#
# Builds the menu-bar app from the Swift files in this folder and puts it at
# ~/Applications/AI Orchestrator.app (bundle id local.ai-orchestrator).
#
# Safe by design: it only ever stops, creates or replaces this app's own
# bundle. It never quits, modifies or removes Claude, Codex, Cursor, your
# accounts, your chats, or any of your folders.
# ------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_ID="local.ai-orchestrator"
APP="${AIO_APP_PATH:-$HOME/Applications/AI Orchestrator.app}"
EXE="AIOrchestrator"
SOURCES=(AIOrchestrator.swift Orchestrator.swift T3.swift Board.swift Hub.swift OneWindow.swift)

echo ""
echo "  AI Orchestrator installer"
echo "  ─────────────────────────"

major="$(sw_vers -productVersion | cut -d. -f1)"
if (( major < 14 )); then
  echo "  This needs macOS 14 (Sonoma) or newer."
  exit 1
fi

for f in "${SOURCES[@]}"; do
  [[ -f "$f" ]] || { echo "  Missing $f. Run this from the repository folder."; exit 1; }
done

if ! xcode-select -p >/dev/null 2>&1; then
  echo "  One-time step: Apple's command line developer tools are needed."
  echo "  A window will pop up. Click Install, wait for it to finish, then run this again."
  xcode-select --install >/dev/null 2>&1 || true
  exit 0
fi

# Never overwrite some other app that happens to live at the same path.
if [[ -d "$APP" ]]; then
  existing="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$existing" != "$BUNDLE_ID" ]]; then
    echo "  $APP already exists and isn't this build (bundle id: ${existing:-unknown})."
    echo "  Set AIO_APP_PATH to install somewhere else, for example:"
    echo "    AIO_APP_PATH=\"\$HOME/Applications/AI Orchestrator OSS.app\" ./install.command"
    exit 1
  fi
fi

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

echo "  Building (takes a few minutes)…"
swiftc -O -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" \
  -o "$BUILD/$EXE" "${SOURCES[@]}"

echo "  Drawing the app icon…"
if [[ -f make-icon.swift ]] && swift make-icon.swift "$BUILD/AppIcon.iconset" >/dev/null 2>&1; then
  iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/AppIcon.icns" 2>/dev/null || true
fi

# Stop a running copy of this app only (exact process name; can't match Claude, Codex or Cursor).
pkill -x "$EXE" 2>/dev/null || true
sleep 0.5

mkdir -p "$(dirname "$APP")"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/$EXE" "$APP/Contents/MacOS/$EXE"
if [[ -f "$BUILD/AppIcon.icns" ]]; then cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"; fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AI Orchestrator</string>
  <key>CFBundleDisplayName</key><string>AI Orchestrator</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>AI Orchestrator brings the Claude window you pick to the front.</string>
</dict>
</plist>
PLIST

# Sign with a stable identity when one exists, so keychain "Always Allow" survives rebuilds.
# Set AIO_SIGN_ID to choose one; otherwise the first "Apple Development" identity, else ad-hoc.
SIGN_ID="${AIO_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')}"
if [[ -n "$SIGN_ID" ]] && codesign --force --sign "$SIGN_ID" --timestamp=none "$APP" >/dev/null 2>&1; then
  echo "  Signed with your Apple Development identity."
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
  echo "  Signed ad-hoc (macOS may ask for keychain access again after each rebuild)."
fi

# Command-line helpers: ai-route, idea, orch.
mkdir -p "$HOME/.local/bin"
for tool in ai-route idea orch; do
  if [[ -f "bin/$tool" ]]; then chmod +x "bin/$tool"; ln -sf "$PWD/bin/$tool" "$HOME/.local/bin/$tool"; fi
done

open "$APP"

echo ""
echo "  ✓ Installed: $APP"
echo ""
echo "  • It finds your Claude, Codex and Cursor logins on its own; add more in Settings."
echo "  • If macOS asks about \"Claude Safe Storage\", click Always Allow"
echo "    (that's how it reads usage from your existing Claude logins)."
echo ""
