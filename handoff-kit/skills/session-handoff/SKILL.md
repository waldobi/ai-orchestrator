---
name: session-handoff
description: Use when the user is switching tasks, wrapping up, says the session is long or slow, or after roughly 150+ turns: save state to the branch's handoff note (.handoff/<branch>.md, or HANDOFF.md outside a git repo) so work continues in a fresh session.
---

# Hand off to a fresh session

Most token use comes from long sessions re-reading their own history every turn. Once a session is long, or the topic changes, it's cheaper to save what matters to a file and start fresh.

## When to use
- The user asks to hand off, wrap up, save progress, or start fresh.
- The user is about to switch to an unrelated task in the same session.
- The session has run long (roughly 150+ turns, or it's carrying lots of old file contents and tool output). Suggest a handoff once at a natural stopping point — not every turn.

## Steps
1. Finish or cleanly pause the current change so the code works (or clearly note what's broken).
2. Write and commit the handoff note exactly as `~/.claude/commands/handoff.md` (the `/handoff` command) describes: `.handoff/<branch>.md` at the repo root, or `HANDOFF.md` outside a git repo, committed with a `Handoff:` message and not pushed.
3. If `PLAN.md` exists, tick off completed steps there too.
4. Tell the user: run `/clear` or open a new session, with any account. On this branch the note shows up by itself; from anywhere else, `/pickup` finds it. If the next part is routine, suggest Sonnet for it.

## When resuming
Follow `/pickup` (`~/.claude/commands/pickup.md`). Don't re-read files the note already summarizes unless you need to edit them.

## Lighter alternative
To keep going on the same task in the same session, suggest `/compact` — ideally before the context gets very large.
