---
description: Pick up work from this branch's handoff note
---
Pick up the work another session or account handed off.

1. Read `.handoff/<branch>.md` for the current branch (branch name with every character that isn't a letter, digit, `.`, `_` or `-` turned into `-`), or `HANDOFF.md` outside a git repo. If there's no note here, run `/usr/bin/python3 "$HOME/.handoff-kit/bin/handoff-hook.py" list` to see the notes from the last two weeks across all projects and worktrees, newest first. If the user named a project or branch, take that note. Otherwise, if the newest note is from this repo (any of its worktrees), take it and say which in one line; if not, show the list and ask which to continue. A note in another worktree belongs to the branch checked out there, so do the work in that folder.
2. Check the note against reality in the note's folder: `git status`, `git log --oneline -5`, and the PR if it names one. Say in one line if anything has moved since the note was written.
3. Give a two-line summary of where things stand and the next step, then carry on with it unless the note lists an open question that blocks it; in that case ask that question first.

$ARGUMENTS
