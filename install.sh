#!/bin/bash
# One-line install for AI Orchestrator:
#   curl -fsSL https://raw.githubusercontent.com/waldobi/ai-orchestrator/main/install.sh | bash
# Add the Claude Code handoff kit too:
#   curl -fsSL https://raw.githubusercontent.com/waldobi/ai-orchestrator/main/install.sh | bash -s -- --handoff-kit
#
# Clones (or updates) the repo in ~/ai-orchestrator (set AIO_DIR to change it), then builds and installs the app.
set -euo pipefail

REPO="https://github.com/waldobi/ai-orchestrator.git"
DIR="${AIO_DIR:-$HOME/ai-orchestrator}"
KIT=0; APP=1
for a in "$@"; do
  case "$a" in
    --handoff-kit) KIT=1 ;;
    --handoff-kit-only) KIT=1; APP=0 ;;
    *) echo "Unknown option: $a (use --handoff-kit or --handoff-kit-only)"; exit 1 ;;
  esac
done

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Apple's command line developer tools are needed. A window will pop up: click Install,"
  echo "wait for it to finish, then run this command again."
  xcode-select --install >/dev/null 2>&1 || true
  exit 0
fi

if [[ -d "$DIR/.git" ]]; then
  echo "Updating $DIR…"
  git -C "$DIR" pull --ff-only --quiet
else
  echo "Downloading to $DIR…"
  git clone --quiet --depth 1 "$REPO" "$DIR"
fi

if (( APP )); then "$DIR/install.command"; fi
if (( KIT )); then "$DIR/handoff-kit/install.sh"; fi
