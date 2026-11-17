---
description: Write or refresh this branch's handoff note so another Claude account (or Codex, or Cursor) can pick up the work
---
Write the handoff note for the work in this session.

1. Find the note's path: `.handoff/<branch>.md` at the repo root, with every character that isn't a letter, digit, `.`, `_` or `-` in the branch name turned into `-` (so `claude/fix-login` becomes `.handoff/claude-fix-login.md`). If the session's folder isn't a git repo but the work was in a repo below it (for example under ~/Code), use that repo. Only if the work isn't in any git repo, use `HANDOFF.md` in the current folder.
2. If the repo has `.handoff/README.md`, follow its format. Otherwise use these sections: Goal, Done, In progress, Next steps (numbered, the first one is the exact next action), Open questions for the user, Gotchas, Check it.
3. Rewrite the note so it describes the state right now. Replace old content instead of appending a history. Keep it under about 60 lines. Name real files, commands and PR numbers. Say whether the working tree has uncommitted changes. Never put secrets, keys or tokens in it.
4. Commit the note on this branch with a message starting `Handoff:`. Commit only the note unless the user asked for more. Don't push just for the note; it goes up with the next push. Other accounts on the same machine read it straight from the folder.
5. Reply with one line: the note's path and the first next step.

$ARGUMENTS
