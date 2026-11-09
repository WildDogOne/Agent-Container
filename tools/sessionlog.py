#!/usr/bin/env python3
"""Host-side session sink for Agent-Container.

`run.sh --sink <base>` calls this *after* a session ends (on the host, never
inside the sandbox) to turn a disposable sandbox run into a queryable record:
the git delta it produced, session metadata, and pointers to the harness's own
session state and the proxy flow log. It writes:

  <base>/<session>/record.json    the trustworthy summary (written by run.sh's
                                  exit path, not by the agent)
  <base>/<session>/changes.patch  git diff of what the session changed
  <base>/index.jsonl              one appended line per session (the queryable
                                  central index)

It never parses a harness's transcript format: it records the harness `state`
paths and the flow-log dir so the transcript is one hop away, and keeps the
sandbox's own guarantees intact (host-side only, no new egress).

Stdlib only.
"""

import argparse
import json
import os
import subprocess
import sys


def git(worktree, *args):
    """Run git in worktree; return stdout, or None if git is absent/errors."""
    try:
        out = subprocess.run(
            ["git", "-C", worktree, *args],
            capture_output=True, text=True, timeout=60,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return out.stdout if out.returncode == 0 else None


def status_paths(worktree):
    """Changed paths from `git status --porcelain` (staged, unstaged, untracked)."""
    raw = git(worktree, "status", "--porcelain")
    if not raw:
        return [], False
    paths = []
    for line in raw.splitlines():
        if not line.strip():
            continue
        # XY<space>path, or for renames: XY<space>old -> new
        rest = line[3:]
        if " -> " in rest:
            rest = rest.split(" -> ", 1)[1]
        rest = rest.strip().strip('"')
        if rest:
            paths.append(rest)
    return paths, True


def main(argv=None):
    ap = argparse.ArgumentParser(description="Record a finished Agent-Container session.")
    ap.add_argument("--base", required=True, help="sink base directory (host path)")
    ap.add_argument("--session", required=True, help="session id (path-safe)")
    ap.add_argument("--harness", required=True)
    ap.add_argument("--worktree", required=True, help="the $PWD the session ran in")
    ap.add_argument("--head-before", default="")
    ap.add_argument("--head-after", default="")
    ap.add_argument("--start", default="", help="ISO-8601 UTC session start")
    ap.add_argument("--end", default="", help="ISO-8601 UTC session end")
    ap.add_argument("--exit", type=int, default=None, dest="exit_code")
    ap.add_argument("--state-path", action="append", default=[],
                    help="absolute host path of a harness state dir (repeatable)")
    ap.add_argument("--flow-dir", default="", help="proxy flow-log dir, if --proxy-logs")
    args = ap.parse_args(argv)

    if not args.session or args.session in (".", "..") or "/" in args.session or args.session.startswith("."):
        print(f"sessionlog: refusing unsafe session id {args.session!r}", file=sys.stderr)
        return 2

    wt = os.path.abspath(args.worktree)
    repo_root = (git(wt, "rev-parse", "--show-toplevel") or "").strip() or None
    branch = (git(wt, "rev-parse", "--abbrev-ref", "HEAD") or "").strip() or None
    is_git = repo_root is not None

    commits = []
    changed = []
    diffstat = ""
    patch = ""
    dirty = False
    hb = args.head_before.strip()
    ha = args.head_after.strip()

    if is_git:
        if hb and ha and hb != ha:
            log = git(wt, "log", "--format=%H%x09%s", f"{hb}..{ha}")
            if log:
                for line in log.splitlines():
                    sha, _, subj = line.partition("\t")
                    commits.append({"sha": sha, "subject": subj})
            names = git(wt, "diff", "--name-only", f"{hb}..{ha}")
            if names:
                changed += [n for n in names.splitlines() if n]
            diffstat = (git(wt, "diff", "--stat", f"{hb}..{ha}") or "").strip()
            patch = git(wt, "diff", f"{hb}..{ha}") or ""
        sp, dirty = status_paths(wt)
        changed += sp
        if dirty and not patch:
            # No commits moved HEAD: capture the working-tree diff (tracked files).
            patch = git(wt, "diff", "HEAD") or ""
        changed = sorted(set(changed))

    record = {
        "session": args.session,
        "harness": args.harness,
        "worktree": wt,
        "repo": repo_root,
        "branch": branch,
        "started": args.start or None,
        "ended": args.end or None,
        "exit": args.exit_code,
        "head_before": hb or None,
        "head_after": ha or None,
        "commits": commits,
        "changed_files": changed,
        "diffstat": diffstat or None,
        "dirty": dirty,
        "state_paths": args.state_path,
        "flow_log_dir": args.flow_dir or None,
    }

    sess_dir = os.path.join(args.base, args.session)
    try:
        os.makedirs(sess_dir, exist_ok=True)
        with open(os.path.join(sess_dir, "record.json"), "w") as f:
            json.dump(record, f, indent=2, sort_keys=True)
            f.write("\n")
        with open(os.path.join(sess_dir, "changes.patch"), "w") as f:
            f.write(patch or "")
        index_line = {
            "session": args.session,
            "ended": args.end or None,
            "harness": args.harness,
            "repo": repo_root,
            "branch": branch,
            "exit": args.exit_code,
            "head_after": ha or None,
            "n_commits": len(commits),
            "n_changed": len(changed),
            "dirty": dirty,
            "dir": sess_dir,
        }
        with open(os.path.join(args.base, "index.jsonl"), "a") as f:
            f.write(json.dumps(index_line, sort_keys=True) + "\n")
    except OSError as e:
        print(f"sessionlog: could not write sink: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # never break a session teardown over a sink hiccup
        print(f"sessionlog: unexpected error: {e}", file=sys.stderr)
        sys.exit(0)
