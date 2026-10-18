"""Publish an addon to its own GitHub repo: its folder's history, split from the workspace.

  python tools/wowf/cli.py publish ADDON [--repo URL] [--push]
  python tools/wowf/cli.py publish --scan RANGE [--push]   # the privacy scan alone; --push: then `git push`, only
                                                           # when it's clean (the workspace: origin/main..HEAD)

Development stays in this workspace (the shared tools and skills). The addon's repo gets only its folder's
commits (`git subtree split`), so players and CurseForge's source link see the addon alone:
1. refuse while the addon folder has uncommitted changes (the split takes committed history only);
2. split into the branch publish/<addon>. The same commits get the same IDs every time, so later publishes are
   plain fast-forward pushes;
3. scan the split's whole history for anything private: this machine's paths and WTF account names
   (wowf.local.json and the clients' WTF\\Account folders), user paths, AppData, account-ID shapes, and email
   addresses other than noreply ones and the committer's own. Only counts are printed, never the strings, and a
   hit stops the publish;
4. with --push and --repo, push publish/<addon> to the repo's main. Never forced: a repo GitHub created with a
   README or LICENSE refuses, and the message gives the guarded first push to run after keeping its LICENSE
   (wowf-deploy, "Publishing to the addon's own repo"). Without --push it stops after the scan and prints the
   push command.

- ADDON is a workspace folder name, an absolute path, or `.` inside the addon's folder (as `package`)
- Done for BuffettForever 1.0.0 (github.com/Typheous1979/BuffettForever).
"""
import argparse
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import config  # noqa: E402
from package import resolve_addon  # noqa: E402

GENERIC = {"program files", "program files (x86)", "world of warcraft", "_classic_beta_", "_forever_", "interface",
           "addons", "account", "onedrive", "documents", "projects", "wow forever", "savedvariables", "wtf"}
PATTERNS = [
    ("Windows user paths", re.compile(r"[A-Za-z]:\\+Users\\+[^\\\s]+")),
    ("POSIX user paths", re.compile(r"/[cC]/Users/[^/\s]+")),
    ("AppData paths", re.compile(r"AppData[\\/]+(?:Local|Roaming|LocalLow)\b")),
    ("account-ID shapes", re.compile(r"\b\d{6,}#\d\b")),
]
# An address starts with a letter or digit, so "+@unittest.skipUnless" (a diff line's decorator) isn't one.
EMAIL = re.compile(r"(?<![A-Za-z0-9._%+-])[A-Za-z0-9][A-Za-z0-9._%+-]*@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")
RESERVED = re.compile(r"@(?:[A-Za-z0-9-]+\.)*(?:example\.(?:com|org|net)|example|test|invalid|localhost)$", re.I)


def private_hits(text, secrets=(), own_email=None):
    """{label: count} of what mustn't be published in text: each of secrets (exact strings), the PATTERNS, and
    email addresses that aren't noreply ones, reserved example domains (RFC 2606) or own_email. Labels with no hit
    are left out."""
    hits = {}
    found = sum(1 for s in secrets if s and s in text)
    if found:
        hits["this machine's paths or account names"] = found
    for label, pattern in PATTERNS:
        n = len(pattern.findall(text))
        if n:
            hits[label] = n
    emails = [e for e in EMAIL.findall(text) if "noreply" not in e.lower() and not RESERVED.search(e)
              and (not own_email or e.lower() != own_email.lower())]
    if emails:
        hits["email addresses"] = len(emails)
    return hits


def local_secrets(root):
    """The strings of wowf.local.json (paths, and their distinctive parts) and the WTF account folder names of
    the clients found. Empty outside a workspace."""
    secrets = set()
    try:
        cfg = config.load(root)
    except Exception:   # a folder with no wowf.config.json (a test repo)
        return secrets

    def walk(value):
        if isinstance(value, dict):
            for v in value.values():
                walk(v)
        elif isinstance(value, list):
            for v in value:
                walk(v)
        elif isinstance(value, str) and len(value) >= 4:
            secrets.add(value)
            for part in re.split(r"[\\/]", value):
                if len(part) >= 6 and part.lower() not in GENERIC:
                    secrets.add(part)

    walk(cfg.get("_local", {}))
    try:
        clients = config.discover_clients(cfg)   # {key: {"dir": the client folder, ...}}
    except Exception:
        clients = {}
    for client in clients.values():
        accounts = os.path.join(client["dir"], "WTF", "Account")
        if os.path.isdir(accounts):
            for name in os.listdir(accounts):
                if len(name) >= 4 and name.lower() != "savedvariables":
                    secrets.add(name)
    return secrets


def _git(cwd, *args, check=True):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, encoding="utf-8",
                          errors="replace", check=check)


def added_text(log):
    """What a `git log -p -U0` adds: the commit headers and messages, and the diffs' added lines. Removed lines
    are left out: they were added (and scanned) by an earlier commit, or are already published."""
    return "\n".join(line for line in log.splitlines() if not line.startswith("-"))


def scan(top, ref):
    """Print the privacy scan of ref's history (a branch or a range); returns 0 when clean, 1 on a hit."""
    own = _git(top, "config", "user.email", check=False).stdout.strip() or None
    log = added_text(_git(top, "log", "-p", "-U0", ref).stdout)
    hits = private_hits(log, local_secrets(top), own)
    if hits:
        print(f"publish: {ref}'s history holds private strings; nothing pushed. Counts only:")
        for label, n in hits.items():
            print(f"  {label}: {n}")
        return 1
    print(f"publish: the scan of {ref} found nothing private (paths, account names, emails)")
    return 0


def main(argv):
    p = argparse.ArgumentParser(prog="wowf publish")
    p.add_argument("addon", nargs="?")
    p.add_argument("--repo", help="the addon's own repo, e.g. https://github.com/<you>/<Addon>.git")
    p.add_argument("--push", action="store_true", help="push the split to the repo's main (never forced)")
    p.add_argument("--scan", metavar="RANGE", help="only scan a branch or range of the workspace (no split); with "
                                                       "--push, then `git push` the current branch, only when clean")
    a = p.parse_args(argv)
    if a.scan:
        top = _git(os.getcwd(), "rev-parse", "--show-toplevel").stdout.strip()
        if scan(top, a.scan):
            return 1
        if not a.push:
            return 0
        pushed = _git(top, "push", check=False)   # the gate is this function: no shell pipe can hide its result
        print("publish:", ((pushed.stderr or "") + (pushed.stdout or "")).strip().splitlines()[-1:] or "pushed")
        return 0 if pushed.returncode == 0 else 1
    if not a.addon:
        p.error("an addon, or --scan RANGE")
    root = None if os.path.isabs(a.addon) else config.load()["_root"]
    addon_dir = resolve_addon(a.addon, root)
    name = os.path.basename(addon_dir)
    top = _git(addon_dir, "rev-parse", "--show-toplevel").stdout.strip()
    prefix = os.path.relpath(addon_dir, top).replace(os.sep, "/")
    dirty = _git(top, "status", "--porcelain", "--", prefix).stdout.strip()
    if dirty:
        print(f"publish: {prefix} has uncommitted changes; commit them first (the split takes committed history only):")
        print(dirty)
        return 1
    split = _git(top, "subtree", "split", f"--prefix={prefix}", check=False)
    if split.returncode != 0:
        print("publish: git subtree split failed:", (split.stderr or split.stdout).strip().splitlines()[-1:])
        return 1
    sha = split.stdout.strip().splitlines()[-1]
    branch = f"publish/{name.lower()}"
    _git(top, "branch", "-f", branch, sha)
    count = _git(top, "rev-list", "--count", branch).stdout.strip()
    print(f"publish: {branch} = {sha[:7]}, {count} commits of {prefix} only")
    if scan(top, branch):
        return 1
    if not (a.push and a.repo):
        target = a.repo or "<repo url>"
        print(f"publish: to push: python tools/wowf/cli.py publish {name} --repo {target} --push")
        return 0
    pushed = _git(top, "push", a.repo, f"{branch}:main", check=False)
    out = (pushed.stderr or "") + (pushed.stdout or "")
    if pushed.returncode != 0:
        remote = _git(top, "ls-remote", a.repo, "refs/heads/main", check=False).stdout.split()
        print("publish: the push was refused (not a fast-forward?):", out.strip().splitlines()[-1:])
        if remote:
            print(f"publish: main is at {remote[0][:7]}. If it's only what GitHub created (a README, a LICENSE), copy its"
                  f" LICENSE into {prefix}, commit, publish again, then push once with:")
            print(f"  git push --force-with-lease=main:{remote[0]} {a.repo} {branch}:main")
        return 1
    print(f"publish: pushed {branch} to {a.repo} main")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
