# AI Orchestrator

A macOS menu-bar app that watches your Claude, Codex and Cursor usage limits and sends coding requests to whichever
account has room. It runs entirely on your Mac and reads your existing logins. There is no server and no account to
create. An optional iPhone companion shows the same data over your local network.

## What it does

- **Usage at a glance.** It shows the 5-hour and weekly limits for every Claude login, plus Codex and Cursor, in the
  menu bar and in a small desktop strip you can drag anywhere.
- **Switching.** Click an account to bring its Claude window to the front.
- **Requests and routing.** Type a request, pick a project folder, and AI Orchestrator plans, builds and reviews it
  across Claude, Codex and Cursor. It picks the account whose limit resets soonest, so you use plan capacity before it
  expires. Each step runs in its own git worktree, and nothing merges until you press Merge.
- **Spend.** Optionally import bank or card CSVs and add admin API keys to see what each tool costs you per month and
  per repo.
- **CLI helpers.** `ai-route` sends a job to the tool with the most room, `idea` adds to a backlog and `orch` opens
  the request window.

## Requirements

- macOS 14 (Sonoma) or newer, Apple silicon or Intel
- Xcode Command Line Tools (`xcode-select --install`)
- At least one of these, signed in:
  - [Claude desktop app](https://claude.ai/download) and/or the Claude Code CLI (`claude`)
  - OpenAI Codex CLI (`codex`)
  - Cursor CLI (`cursor-agent`)
- Optional: [T3 Code](https://www.npmjs.com/package/t3) (`npm i -g t3`, then `t3 service install`). The request
  engine uses it when it's running.

## Install (one command)

```bash
curl -fsSL https://raw.githubusercontent.com/waldobi/ai-orchestrator/main/install.sh | bash
```

That clones the repo to `~/ai-orchestrator`, builds the app and opens it. Run it again to update. To also install the
Claude Code handoff kit (see below), add `-s -- --handoff-kit`:

```bash
curl -fsSL https://raw.githubusercontent.com/waldobi/ai-orchestrator/main/install.sh | bash -s -- --handoff-kit
```

If you'd rather read the script first, clone the repo and run `./install.command` yourself.

The installer compiles the six Swift files with `swiftc`, which takes a few minutes. It installs
`~/Applications/AI Orchestrator.app` and opens it. It won't overwrite a different app that already sits at that path.
Set `AIO_APP_PATH` to install somewhere else.

For a quick compile check without installing:

```bash
swiftc -parse-as-library -target arm64-apple-macos14.0 -o /tmp/aio AIOrchestrator.swift Orchestrator.swift T3.swift Board.swift Hub.swift OneWindow.swift
```

## Connecting your accounts

AI Orchestrator finds accounts on its own:

| Tool | How it's found |
|---|---|
| Claude (desktop) | Your normal Claude profile, plus any extra Claude profiles you've made. Usage comes from your signed-in session. macOS asks once for "Claude Safe Storage"; click Always Allow. |
| Claude Code CLI | `~/.claude`, plus any `~/.claude-<name>` folder that has a `.claude.json`. Run `CLAUDE_CONFIG_DIR=~/.claude-work claude` once to add a second login. |
| Codex | `~/.codex` and any extra Codex homes you add in Settings. |
| Cursor | `cursor-agent` on your PATH. |

Open **Settings** from the menu-bar icon to rename accounts, hide them, set a monthly budget, or add admin API keys.
OpenAI and Anthropic admin keys are optional and only used for exact API spend. Keys are kept in your login Keychain
under the service `local.ai-orchestrator`. They never go into files.

### Configuration

| Setting | How to change it |
|---|---|
| Extra folders to search for `claude`, `codex`, `cursor-agent` and `t3` | `defaults write local.ai-orchestrator binDirs "$HOME/.npm-global/bin:/some/other/bin"` (or the `AIO_BIN_DIRS` env var) |
| T3 server address | `defaults write local.ai-orchestrator t3Origin http://127.0.0.1:3773` |
| Install location | `AIO_APP_PATH=... ./install.command` |
| Signing identity | `AIO_SIGN_ID="Apple Development: …" ./install.command`. Otherwise it uses the first Apple Development identity, then falls back to ad-hoc. |

## Where data lives

Everything stays on your Mac:

- `~/Library/Application Support/local.ai-orchestrator/`: usage history, token totals, the ledger, requests and `status.json`
- `~/Library/Caches/local.ai-orchestrator/`: parsed transcript cache
- UserDefaults domain `local.ai-orchestrator`: names, layout and preferences
- Keychain service `local.ai-orchestrator`: optional API keys you add

To remove the app, quit it from its menu, then delete the app and those folders.

## Safety

The app and installer never quit, change or delete Claude, Codex or Cursor, their profiles, or your folders. The
request engine refuses `sudo`, `kill`, `pkill`, `killall`, `osascript … quit`, `git push` and keychain dumps inside
agent runs. Every edit happens in a separate worktree until you merge it.

## iPhone companion (optional)

`iPhone/` holds a SwiftUI app and a widget. On the Mac, run the feed:

```bash
bin/phone-feed install   # starts it at login (LaunchAgent local.ai-orchestrator.phone-feed, port 47615, Bonjour)
bin/phone-feed code      # prints the pairing code
```

Then open `iPhone/AIOrchestratorPhone.xcodeproj` in Xcode and set **Signing & Capabilities** for both targets:

1. Pick your own Team.
2. Change the bundle identifiers (`local.ai-orchestrator.phone` and `.phone.widget`) to ones you own.
3. Change the App Group (`group.local.ai-orchestrator.phone`) to match, in both entitlements files and in
   `iPhone/Shared/Feed.swift`.

Run it on your iPhone. It finds the Mac by Bonjour on the same Wi-Fi and asks for the pairing code. To use it away
from home, put both devices on a private network such as Tailscale and enter the Mac's name in the app's settings.

## Handoff kit for Claude Code (optional)

`handoff-kit/` adds three slash commands and two hooks, so work moves cleanly between Claude accounts (or to Codex or
Cursor) when one nears its limit:

- `/handoff` writes `.handoff/<branch>.md` (goal, done, next steps, gotchas) and commits it on the branch.
- `/pickup` finds the newest note, checks it against `git status` and the log, and carries on.
- `/handoff-all` asks every live session on this Mac to write its note, then rebuilds notes from git for any repo
  with unsaved work this week.
- A SessionStart hook shows the branch's note when a session opens. A Stop hook asks for a handoff when the account reaches 90% and again at 97% (set `HANDOFF_AT` to change the first
  one). It reads that usage from the kit's status line.

Install it with `handoff-kit/install.sh`, or use the `--handoff-kit` flag above. It copies the files into
`~/.claude/commands`, `~/.claude/skills` and `~/.handoff-kit`. It adds its hooks to `~/.claude/settings.json` after
backing that file up, and leaves an existing status line alone. For a second Claude login, run it again with
`CLAUDE_CONFIG_DIR=~/.claude-<name>`.

## Project layout

| File | What's in it |
|---|---|
| `AIOrchestrator.swift` | Accounts, usage reading, menu bar, strip, report and settings windows, spend and ledger |
| `Orchestrator.swift` | Request window and plan, build and review steps across tools |
| `T3.swift` | WebSocket client for the local T3 Code server |
| `Hub.swift`, `Board.swift`, `OneWindow.swift` | Router, overview board and the combined window |
| `bin/` | `ai-route`, `idea`, `orch`, `phone-feed` |
| `iPhone/` | Companion app and widget |
| `handoff-kit/` | `/handoff`, `/pickup`, `/handoff-all`, their hooks and installer |
| `install.sh` | One-line installer (clone or update, then `install.command`) |

## License

MIT. See [LICENSE](LICENSE).
