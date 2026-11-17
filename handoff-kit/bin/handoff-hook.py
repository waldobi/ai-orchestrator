#!/usr/bin/env python3
"""Claude handoff kit: hooks for SessionStart and Stop.

session-start: if this branch has a handoff note (.handoff/<branch>.md),
               put it in front of Claude so a new account picks up from it.
stop:          when this session's plan usage (saved by statusline.sh) is at or
               over HANDOFF_AT (default 90) on the five-hour or weekly window,
               ask Claude once to write the handoff note before it stops.
               It asks again once at 97%. It never stops or quits anything.
"""
import json, os, re, subprocess, sys, time, datetime

HOME = os.path.expanduser("~")
KIT = os.path.join(HOME, ".handoff-kit")
LEVELS = sorted({int(os.environ.get("HANDOFF_AT", "90")), 97})


def git(cwd, *args):
    try:
        return subprocess.run(["git", "-C", cwd, *args], capture_output=True,
                              text=True, timeout=5).stdout.strip()
    except Exception:
        return ""


def note_path(cwd):
    root = git(cwd, "rev-parse", "--show-toplevel")
    if not root:
        return None, None
    branch = git(cwd, "branch", "--show-current") or "detached"
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", branch).strip("-") or "detached"
    return os.path.join(root, ".handoff", slug + ".md"), branch


def stamp(path):
    return datetime.datetime.fromtimestamp(os.path.getmtime(path)).strftime("%b %d %I:%M %p")


def worktrees(cwd):
    out = git(cwd, "worktree", "list", "--porcelain")
    return [line[9:] for line in out.splitlines() if line.startswith("worktree ")]


def notes_in(root):
    """Handoff notes in one folder: .handoff/*.md (not the README) and a root HANDOFF.md."""
    found = []
    d = os.path.join(root, ".handoff")
    try:
        found = [os.path.join(d, n) for n in os.listdir(d)
                 if n.endswith(".md") and n != "README.md"]
    except OSError:
        pass
    if os.path.isfile(os.path.join(root, "HANDOFF.md")):
        found.append(os.path.join(root, "HANDOFF.md"))
    return found


def recent_notes(roots, days):
    seen, notes = set(), []
    for root in roots:
        for p in notes_in(root):
            real = os.path.realpath(p)
            if real in seen:
                continue
            seen.add(real)
            try:
                m = os.path.getmtime(p)
            except OSError:
                continue
            if time.time() - m < days * 86400:
                notes.append((m, p))
    return [p for _, p in sorted(notes, reverse=True)]


def first_step(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read(8000).splitlines()
    except OSError:
        return ""
    for i, line in enumerate(lines):
        if re.match(r"\s*#+\s*next step", line, re.I):
            for nxt in lines[i + 1:]:
                if nxt.strip():
                    return re.sub(r"^\s*(\d+[.)]|[-*])\s*", "", nxt).strip()[:100]
    return ""


def child_repos(folder):
    try:
        names = sorted(os.listdir(folder))
    except OSError:
        return []
    return [os.path.join(folder, n) for n in names
            if not n.startswith(".") and os.path.exists(os.path.join(folder, n, ".git"))]


def point_to(notes, intro):
    if notes:
        print(intro + " (newest first):\n"
              + "\n".join(f"- {p} (written {stamp(p)})" for p in notes[:3])
              + "\nMention them to the user in one line in your first reply. If the user "
              "wants to continue one, follow /pickup.")


def session_start(d):
    cwd = d.get("cwd") or os.getcwd()
    path, branch = note_path(cwd)
    fresh = d.get("source") not in ("resume", "compact")
    if not path and not os.path.isfile(os.path.join(cwd, "HANDOFF.md")):
        # A folder of repos (like ~/Code): point at recent notes in the repos below it.
        if fresh:
            roots = [r for c in child_repos(cwd) for r in [c] + worktrees(c)]
            point_to(recent_notes(roots, 3),
                     "No handoff note in this folder, but repos below it have recent ones")
        return
    if not path:
        # Not a git repo: the note is HANDOFF.md in this folder.
        path, label, rel = os.path.join(cwd, "HANDOFF.md"), "this folder", "HANDOFF.md"
        check = "the files here"
    elif os.path.isfile(path):
        label, rel = "branch " + branch, os.path.join(".handoff", os.path.basename(path))
        check = "`git status` and `git log -5`"
    else:
        # No note for this branch. A new session often lands in a fresh worktree,
        # so point at recent notes elsewhere in this repo instead.
        if fresh:
            point_to([p for p in recent_notes(worktrees(cwd), 3) if p != path],
                     "No handoff note for this branch, but this repo has recent ones "
                     "in other worktrees or branches")
        return
    with open(path, encoding="utf-8", errors="replace") as f:
        body = f.read(8000)
    print(f"Handoff note for {label} ({rel}, last written {stamp(path)}). "
          f"Another session or account left this. Check it against {check}, "
          "then continue from its Next steps unless the user asks for "
          "something else. Keep the note up to date as you work.\n\n" + body)


def known_roots():
    """Every folder Claude Code has worked in, the git repos one level below
    folders that aren't repos (like ~/Code), and every worktree of each repo."""
    cfg = os.environ.get("CLAUDE_CONFIG_DIR")
    state = os.path.join(cfg, ".claude.json") if cfg else os.path.join(HOME, ".claude.json")
    try:
        with open(state) as f:
            projects = list((json.load(f).get("projects") or {}).keys())
    except Exception:
        projects = []
    roots, seen = [], set()
    for p in projects:
        if not os.path.isdir(p):
            continue
        cands = [p] if git(p, "rev-parse", "--show-toplevel") else [p] + child_repos(p)
        for c in cands:
            for r in [c] + worktrees(c):
                if os.path.isdir(r) and os.path.realpath(r) not in seen:
                    seen.add(os.path.realpath(r))
                    roots.append(r)
    return roots


def git_lines(cwd, *args):
    try:
        out = subprocess.run(["git", "--no-optional-locks", "-C", cwd, *args],
                             capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return []
    return [line for line in out.splitlines() if line.strip()]


def write_rebuilt(top, branch, path, changed, unpushed):
    """Write a note from git alone. Never replaces a note; commits only the note."""
    fmt = ["--format=%h %ad %s", "--date=format:%b %d"]
    log = git_lines(top, "log", "--since=7.days", "-10", *fmt) or git_lines(top, "log", "-3", *fmt)
    pr = ""
    try:
        r = subprocess.run(["gh", "pr", "view", branch, "--json", "number,title,state"],
                           cwd=top, capture_output=True, text=True, timeout=15)
        if r.returncode == 0:
            p = json.loads(r.stdout)
            pr = f'PR #{p["number"]} "{p["title"]}" ({p["state"].lower()}).'
    except Exception:
        pass
    subject = log[0].split(" ", 3)[-1] if log else "none"
    lines = [f"# Handoff: {branch}", "",
             "> Rebuilt from git by /handoff-all on "
             + datetime.datetime.now().strftime("%b %d %I:%M %p")
             + ". No session wrote this, so the goal and next steps are a best guess. "
             "A session that knows the work should replace it with /handoff.",
             "", "## Goal", f'Not recorded. Latest commit: "{subject}". {pr}'.rstrip(),
             "", "## Done (commits this week)"] + [f"- {c}" for c in log] + ["", "## In progress"]
    if changed:
        lines.append(f"{len(changed)} uncommitted change(s):")
        lines += [f"- `{code}` {name}" for code, name in changed[:15]]
        if len(changed) > 15:
            lines.append(f"- and {len(changed) - 15} more")
    else:
        lines.append("Working tree is clean.")
    if unpushed:
        lines.append(f"{unpushed} commit(s) aren't pushed to any remote yet.")
    lines += ["", "## Next steps",
              "1. Read the uncommitted changes and recent commits above to see what was in progress.",
              "2. Ask the user what's left on this branch before changing anything.",
              "", "## Open questions for the user", "- What is this branch for, and what's left to do?",
              "", "## Gotchas", "- Written from git alone. It knows nothing about decisions made in the session.",
              "", "## Check it", f'git -C "{top}" status', f'git -C "{top}" log --oneline -10', ""]
    os.makedirs(os.path.dirname(path), exist_ok=True)
    try:
        with open(path, "x", encoding="utf-8") as f:  # "x": never overwrite a note a session just wrote
            f.write("\n".join(lines))
    except FileExistsError:
        return "skipped, a session just wrote its own note"
    rel = os.path.relpath(path, top)
    default = git(top, "symbolic-ref", "--short", "refs/remotes/origin/HEAD").split("/", 1)[-1]
    if branch in ("main", "master", "detached") or branch == default:
        return "not committed (default branch)"
    run = lambda *a: subprocess.run(["git", "-C", top, *a], capture_output=True, text=True, timeout=60)
    if run("add", "--", rel).returncode != 0:
        return "not committed (git add failed; is .handoff/ ignored?)"
    if run("commit", "-q", "-m", "Handoff: rebuilt from git by /handoff-all", "--", rel).returncode != 0:
        run("reset", "-q", "--", rel)
        return "not committed (git commit failed)"
    return "committed"


def rebuild(args):
    """For /handoff-all: every repo or worktree with work in the last 7 days and no
    note on its branch gets a note rebuilt from git. Existing notes are left alone."""
    dry = "--dry-run" in args
    now, seen, rows, skipped = time.time(), set(), [], {"clean": 0, "detached": 0}
    for root in known_roots():
        top = git(root, "rev-parse", "--show-toplevel")
        if not top or os.path.realpath(top) in seen:
            continue
        seen.add(os.path.realpath(top))
        changed = [(line[:2].strip(), line[3:]) for line in git_lines(top, "status", "--porcelain")]
        changed = [(c, n) for c, n in changed if not n.startswith((".handoff/", ".claude/worktrees"))
                   and n != ".claude/"]
        last = git(top, "log", "-1", "--format=%ct")
        newest = int(last) if last.isdigit() else 0
        for _, name in changed[:200]:
            try:
                newest = max(newest, os.path.getmtime(os.path.join(top, name)))
            except OSError:
                pass
        if now - newest > 7 * 86400:
            continue
        path, branch = note_path(top)
        if branch == "detached":  # build or screenshot checkouts, not a line of work
            skipped["detached"] += 1
            continue
        unpushed = git(top, "rev-list", "--count", "HEAD", "--not", "--remotes")
        unpushed = int(unpushed) if unpushed.isdigit() else 0
        if not changed and not unpushed:  # everything is already on GitHub
            skipped["clean"] += 1
            continue
        legacy = os.path.join(top, "HANDOFF.md")  # older notes written by session-handoff
        note = path if os.path.isfile(path) else legacy if os.path.isfile(legacy) else None
        if note:
            fresh = os.path.getmtime(note) >= newest - 60
            rows.append(("has a note" if fresh else "note older than latest work", top, branch,
                         "" if note == path else "(HANDOFF.md)"))
        elif dry:
            rows.append(("would rebuild from git", top, branch, ""))
        else:
            rows.append(("rebuilt from git", top, branch,
                         write_rebuilt(top, branch, path, changed, unpushed)))
    if not rows:
        print("No unsaved git work from the last 7 days.")
    for state, top, branch, extra in rows:
        print(f"{state:28} {top.replace(HOME, '~', 1)}  [{branch}]" + (f"  {extra}" if extra else ""))
    if skipped["clean"] or skipped["detached"]:
        print(f"Skipped {skipped['clean']} active this week but clean and pushed, "
              f"and {skipped['detached']} detached checkouts.")


def list_all(_):
    """Recent handoff notes across every project Claude Code knows, newest first (for /pickup)."""
    notes = recent_notes(known_roots(), 14)
    if not notes:
        print("No handoff notes written in the last 14 days.")
    for p in notes[:20]:
        step = first_step(p)
        print(f"{stamp(p)}  {p.replace(HOME, '~', 1)}" + (f"\n    next: {step}" if step else ""))


def fmt_reset(ts):
    try:
        return datetime.datetime.fromtimestamp(int(ts)).strftime("%I:%M %p %a").lstrip("0")
    except Exception:
        return "unknown"


def stop(d):
    if d.get("stop_hook_active"):
        return
    sid = d.get("session_id")
    if not sid:
        return
    try:
        with open(os.path.join(KIT, "usage", sid + ".json")) as f:
            u = json.load(f)
    except Exception:
        return  # no usage seen for this session (no status line here): do nothing
    if time.time() - u.get("saved_at", 0) > 6 * 3600:
        return
    windows = [(k, u[k]) for k in ("five_hour", "seven_day") if k in u]
    if not windows:
        return
    name, w = max(windows, key=lambda kv: kv[1].get("used_percentage", 0))
    pct = float(w.get("used_percentage", 0))
    hit = [lvl for lvl in LEVELS if pct >= lvl]
    if not hit:
        return
    level = hit[-1]
    state = os.path.join(KIT, "state")
    os.makedirs(state, exist_ok=True)
    marker = os.path.join(state, f"{sid}.{level}")
    if os.path.exists(marker):
        return
    open(marker, "w").close()
    path, branch = note_path(d.get("cwd") or os.getcwd())
    where = (f".handoff/{os.path.basename(path)} for branch {branch}" if path
             else "the root of the repo you've been working in (.handoff/<branch>.md), "
                  "or HANDOFF.md in this folder if the work isn't in a git repo,")
    label = "five-hour" if name == "five_hour" else "weekly"
    reason = (f"This Claude account is at {pct:.0f}% of its {label} usage "
              f"(resets {fmt_reset(w.get('resets_at'))}). Before you stop, write the "
              f"handoff note at {where} as /handoff describes (the format is in "
              ".handoff/README.md when the repo has one): goal, done, in progress, "
              "next steps, open questions, gotchas, how to check. Commit it on this "
              "branch with a message starting 'Handoff:' but don't push just for it. "
              "Then tell the user in one line that the handoff is written and another "
              "account can pick up with /pickup.")
    print(json.dumps({"decision": "block", "reason": reason}))


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    d = {}
    if mode in ("session-start", "stop"):
        try:
            d = json.load(sys.stdin)
        except Exception:
            d = {}
    try:
        if mode == "rebuild":
            rebuild(sys.argv[2:])
        else:
            {"session-start": session_start, "stop": stop, "list": list_all}.get(mode, lambda _: None)(d)
    except Exception as e:
        if mode in ("list", "rebuild"):
            print(f"handoff-kit error: {e}")
        # a hook must never get in the way of the session
    sys.exit(0)


if __name__ == "__main__":
    main()
