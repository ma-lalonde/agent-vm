#!/usr/bin/env python3
"""
PreToolUse guard for Bash, Edit, Write, NotebookEdit, Read.

Denies:
  1. git push, full stop -- commit locally, a human pushes. Also blocks
     gh api with DELETE/PATCH/PUT, destructive gh release/repo/ref
     subcommands, gh auth/secret/variable/workflow writes, and curl/wget
     against github.com.
  2. Local git history rewrites (rebase, filter-*, reset --hard/--merge/
     --keep, update-ref, replace, commit --amend, cherry-pick, branch -D,
     tag -d, checkout --orphan, reflog expire, gc --prune, prune).
  3. Privilege escalation: sudo/su/doas/pkexec, in any position of a
     chained command (not just when they're the first word).
  4. Writes / shell redirection / cp / mv / tee / rm targeting ~/.claude/
     or <project>/.claude/, EXCEPT the auto-memory dirs
     (~/.claude/projects/*/memory) and plans dir (~/.claude/plans) that
     Claude Code legitimately writes to.
  5. chattr (would clear file immutability).
  6. (FS scope, opt-out) Writes AND reads outside the whitelisted roots:
     $CLAUDE_PROJECT_DIR + its permissions.additionalDirectories (read from
     the project's .claude/settings.local.json / settings.json, so there is
     one source of truth) + /tmp + /var/tmp. Reads additionally allow all of
     ~/.claude (needed to read memory/CLAUDE.md/hooks) even though writes
     there are blocked by rule 4. Disable with CLAUDE_GUARD_FS_SCOPE=off.
     Extra writable/readable roots via CLAUDE_GUARD_EXTRA_DIRS=path1:path2.

Bypass everything: CLAUDE_GUARD_DISABLED=1.
"""
import json
import os
import re
import shlex
import sys
from pathlib import Path


if os.environ.get("CLAUDE_GUARD_DISABLED") == "1":
    sys.exit(0)


HOME = Path.home()
FS_SCOPE_ENABLED = os.environ.get("CLAUDE_GUARD_FS_SCOPE", "on").lower() != "off"


def deny(reason: str) -> None:
    sys.stdout.write(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": f"claude-guard: {reason}",
        }
    }))
    sys.exit(0)


def resolve(p: str) -> Path:
    return Path(os.path.expanduser(os.path.expandvars(p))).resolve(strict=False)


def path_under(child: Path, root: Path) -> bool:
    try:
        child.relative_to(root)
        return True
    except ValueError:
        return False


def project_root():
    pd = os.environ.get("CLAUDE_PROJECT_DIR")
    return Path(pd).resolve() if pd else None


def additional_directories():
    """Read permissions.additionalDirectories straight from the project's own
    settings, so that list has exactly one place it's maintained."""
    pr = project_root()
    if not pr:
        return []
    dirs = []
    for fname in ("settings.local.json", "settings.json"):
        f = pr / ".claude" / fname
        try:
            data = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        for d in data.get("permissions", {}).get("additionalDirectories", []):
            try:
                dirs.append(resolve(d))
            except (OSError, RuntimeError, ValueError):
                pass
    return dirs


def exception_roots():
    """Paths that must stay writable (and readable) even though they sit
    under a guarded ~/.claude directory."""
    roots = []
    projects_dir = HOME / ".claude" / "projects"
    if projects_dir.is_dir():
        try:
            for child in projects_dir.iterdir():
                mem = child / "memory"
                if mem.is_dir():
                    roots.append(mem)
        except OSError:
            pass
    roots.append(HOME / ".claude" / "plans")
    return roots


def guarded_dirs():
    """Directories the model may never Edit/Write/NotebookEdit into, nor
    reach via Bash file-write tools or shell redirection: its own
    guardrails, global and per-project."""
    dirs = [HOME / ".claude"]
    pr = project_root()
    if pr:
        dirs.append(pr / ".claude")
    return dirs


def writable_roots():
    roots = [Path("/tmp"), Path("/var/tmp")]
    pr = project_root()
    if pr:
        roots.append(pr)
    roots.extend(additional_directories())
    roots.extend(exception_roots())
    for extra in os.environ.get("CLAUDE_GUARD_EXTRA_DIRS", "").split(":"):
        if extra:
            try:
                roots.append(resolve(extra))
            except (OSError, RuntimeError, ValueError):
                pass
    return roots


def readable_roots():
    # Read is allowed everywhere Write is, plus all of ~/.claude (config,
    # memory, hooks) since reading your own guardrails is fine -- only
    # writing to them is the danger, and that's handled by guarded_dirs().
    return writable_roots() + [HOME / ".claude"]


def is_writable(path: Path) -> bool:
    for r in writable_roots():
        if path_under(path, r):
            return True
    return False


def is_readable(path: Path) -> bool:
    for r in readable_roots():
        if path_under(path, r):
            return True
    return False


def split_segments(cmd: str):
    """Top-level split on &&, ||, ;, |, &. Returns None if unparseable."""
    try:
        lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        tokens = list(lex)
    except ValueError:
        return None
    segs, cur = [], []
    for t in tokens:
        if t in ("&&", "||", ";", "|", "&"):
            if cur:
                segs.append(cur)
                cur = []
        else:
            cur.append(t)
    if cur:
        segs.append(cur)
    return segs


PRIVESC_BINS = {"sudo", "su", "doas", "pkexec"}

GIT_REWRITE_SUBS = {
    "rebase", "filter-branch", "filter-repo", "update-ref",
    "replace", "fast-import", "symbolic-ref", "prune",
    "cherry-pick",
}

GIT_FLAG_RULES = [
    ("reset",    ("--hard", "--merge", "--keep")),
    ("commit",   ("--amend",)),
    ("branch",   ("-D", "--delete")),
    ("tag",      ("-d", "--delete")),
    ("checkout", ("--orphan",)),
    ("reflog",   ("expire",)),
    ("gc",       ("--prune",)),
    ("remote",   ("add", "remove", "rm", "rename", "set-url")),
    ("config",   ("remote.", "push.", "url.", "credential.")),
]

GH_WRITE_CHAINS = [
    ("release", "delete"),
    ("release", "edit"),
    ("repo", "delete"),
    ("repo", "edit"),
    ("repo", "archive"),
    ("repo", "rename"),
    ("repo", "transfer"),
    ("ref", "delete"),
    ("auth", "refresh"),
    ("auth", "login"),
    ("auth", "logout"),
    ("auth", "setup-git"),
    ("secret",),
    ("variable",),
    ("workflow", "disable"),
    ("workflow", "enable"),
    ("workflow", "run"),
]

GH_API_BAD_METHOD = re.compile(r"(?:^|[\s=])(?:-X|--method)\s*=?\s*(DELETE|PATCH|PUT)\b", re.I)

HTTP_CLIENTS = {"curl", "wget", "http", "httpie", "xh"}
GITHUB_HOST_RE = re.compile(r"(?:api\.)?github\.com", re.I)

FILE_WRITE_TOOLS = {"tee", "cp", "mv", "ln", "install", "rsync", "dd", "truncate"}

# Any `>`, `>>`, or `tee [-a]` redirection target. Resolved and checked
# against guarded_dirs() below -- deliberately not anchored to ~/.claude so
# it also catches redirection into <project>/.claude by relative or
# absolute path.
REDIR_TARGET_RE = re.compile(r"(?:>>?|\btee\b\s+(?:-a\s+)?)\s*([^\s'\"<>|;&]+)")


def guarded_hit(path_arg: str):
    try:
        rp = resolve(path_arg)
    except (OSError, RuntimeError, ValueError):
        return None
    for r in exception_roots():
        if path_under(rp, r):
            return None
    for g in guarded_dirs():
        if path_under(rp, g):
            return g
    return None


def outside_writable_hit(path_arg: str):
    if not FS_SCOPE_ENABLED:
        return None
    try:
        rp = resolve(path_arg)
    except (OSError, RuntimeError, ValueError):
        return None
    if is_writable(rp):
        return None
    return rp


def outside_readable_hit(path_arg: str):
    if not FS_SCOPE_ENABLED:
        return None
    try:
        rp = resolve(path_arg)
    except (OSError, RuntimeError, ValueError):
        return None
    if is_readable(rp):
        return None
    return rp


def check_redir_to_claude(cmd: str):
    for m in REDIR_TARGET_RE.finditer(cmd):
        target = m.group(1)
        hit = guarded_hit(target)
        if hit:
            try:
                rp = resolve(target)
            except (OSError, RuntimeError, ValueError):
                rp = target
            return f"shell redirection / tee into guarded `{rp}` is blocked"
    return None


def check_bash(cmd: str):
    r = check_redir_to_claude(cmd)
    if r:
        return r

    segs = split_segments(cmd)
    if segs is None:
        return "command failed to tokenize; refusing (set CLAUDE_GUARD_DISABLED=1 to bypass)"

    for seg in segs:
        if not seg:
            continue
        argv0 = os.path.basename(seg[0])

        if argv0 in ("bash", "sh", "zsh", "dash", "ksh") and "-c" in seg:
            return f"shell-bypass via `{argv0} -c` is blocked"
        if argv0 == "env":
            i = 1
            while i < len(seg) and "=" in seg[i] and not seg[i].startswith("/"):
                i += 1
            if i < len(seg):
                inner = os.path.basename(seg[i])
                if inner in ("bash", "sh", "zsh", "dash", "ksh") and "-c" in seg[i + 1:]:
                    return f"shell-bypass via `env ... {inner} -c` is blocked"
        if argv0 == "chattr":
            return "chattr is blocked (would clear immutability)"
        if argv0 in PRIVESC_BINS:
            return f"`{argv0}` is blocked (no privilege escalation)"

        if argv0 == "git" and len(seg) >= 2:
            sub = seg[1]
            args = seg[2:]
            if sub == "push":
                return "git push is blocked (commit locally; a human pushes)"
            if sub in GIT_REWRITE_SUBS:
                return f"git {sub} is blocked (history rewrite)"
            for s, frags in GIT_FLAG_RULES:
                if sub != s:
                    continue
                if not frags:
                    return f"git {sub} is blocked"
                for a in args:
                    for frag in frags:
                        if frag.endswith(".") and a.startswith(frag):
                            return f"git {sub} {frag}* is blocked"
                        if a == frag or a.startswith(frag + "=") or a.startswith(frag + " "):
                            return f"git {sub} with `{frag}` is blocked"
                        if frag in ("add", "remove", "rm", "rename", "set-url",
                                    "expire") and a == frag:
                            return f"git {sub} {frag} is blocked"

        if argv0 == "gh" and len(seg) >= 2:
            for chain in GH_WRITE_CHAINS:
                if tuple(seg[1:1 + len(chain)]) == chain:
                    return f"gh {' '.join(chain)} is blocked"
            if seg[1] == "api":
                joined = " ".join(seg[2:])
                if GH_API_BAD_METHOD.search(joined):
                    return "gh api with DELETE/PATCH/PUT method is blocked"

        if argv0 in HTTP_CLIENTS:
            if any(GITHUB_HOST_RE.search(a) for a in seg[1:]):
                return f"`{argv0}` against github.com is blocked"

        if argv0 in FILE_WRITE_TOOLS or argv0 == "rm":
            for a in seg[1:]:
                if a.startswith("-"):
                    continue
                hit = guarded_hit(a)
                if hit:
                    return f"`{argv0}` targeting guarded path `{hit}` is blocked"
                outside = outside_writable_hit(a) if argv0 in FILE_WRITE_TOOLS else None
                if outside is not None:
                    return (
                        f"`{argv0}` writing outside project scope: `{outside}` "
                        f"(allowed: $CLAUDE_PROJECT_DIR + additionalDirectories + /tmp; "
                        f"add via CLAUDE_GUARD_EXTRA_DIRS or set CLAUDE_GUARD_FS_SCOPE=off)"
                    )

    return None


def check_fs_tool(file_path: str):
    if not file_path:
        return None
    hit = guarded_hit(file_path)
    if hit:
        return f"path is inside guarded directory `{hit}`"
    outside = outside_writable_hit(file_path)
    if outside is not None:
        return (
            f"write outside project scope: `{outside}` "
            f"(allowed: $CLAUDE_PROJECT_DIR + additionalDirectories + /tmp; "
            f"add via CLAUDE_GUARD_EXTRA_DIRS or set CLAUDE_GUARD_FS_SCOPE=off)"
        )
    return None


def check_read_tool(file_path: str):
    if not file_path:
        return None
    # Reading your own guardrails/memory is fine; only writing to them
    # is guarded -- so no guarded_dirs() check here, just the FS scope.
    outside = outside_readable_hit(file_path)
    if outside is not None:
        return (
            f"read outside whitelisted scope: `{outside}` "
            f"(allowed: $CLAUDE_PROJECT_DIR + additionalDirectories + /tmp + ~/.claude; "
            f"add via CLAUDE_GUARD_EXTRA_DIRS or set CLAUDE_GUARD_FS_SCOPE=off)"
        )
    return None


def main():
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        sys.exit(0)

    tool = payload.get("tool_name", "")
    tin = payload.get("tool_input") or {}

    reason = None
    if tool == "Bash":
        reason = check_bash(tin.get("command", "") or "")
    elif tool in ("Edit", "Write"):
        reason = check_fs_tool(tin.get("file_path", "") or "")
    elif tool == "NotebookEdit":
        reason = check_fs_tool(tin.get("notebook_path", "") or "")
    elif tool == "Read":
        reason = check_read_tool(tin.get("file_path", "") or "")

    if reason:
        deny(reason)
    sys.exit(0)


if __name__ == "__main__":
    main()
