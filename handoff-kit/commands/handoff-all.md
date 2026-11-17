---
description: Hand off every live Claude session and every project with work this week, so another account can pick up anywhere
---
Hand off all the work on this Mac, because a Claude account is close to its usage limit. Keep your own replies short; usage is low.

1. Message every live session. Use ListAgents (load it and SendMessage with ToolSearch if they're deferred). Send each peer session on this Mac this message as is, skipping yourself, cloud sessions and sessions on other machines:
   > The user ran /handoff-all in another session because a Claude account is close to its usage limit. Please write and commit this session's handoff note now, following ~/.claude/commands/handoff.md (the /handoff command): the note only, don't push. Then reply to me in one line with the note's path and its first next step, or "nothing to hand off" if this session has no project work. If you're in the middle of a step, finish it first, and carry on afterwards as before.

   If ListAgents or SendMessage isn't available here, say so in one line and go on.
2. If this session has project work of its own, write its note too, as /handoff describes.
3. Run this in the background (not in the foreground), so the live sessions get about two and a half minutes to write their own notes first:
   `sleep 150; /usr/bin/python3 "$HOME/.handoff-kit/bin/handoff-hook.py" rebuild`
   It checks every git repo and worktree Claude Code knows about. Each one with unsaved work from the last 7 days (uncommitted changes, or commits that aren't pushed) and no note on its branch gets a note rebuilt from git, committed on feature branches and left uncommitted on the default branch. It never changes an existing note.
4. When it finishes, reply with a short report: which sessions replied and their note paths, what the rebuild wrote, any note marked "note older than latest work", and any session that hasn't replied yet. End with: "From any account, /pickup continues from these notes." If a session replies after that, add it in one line.

$ARGUMENTS
