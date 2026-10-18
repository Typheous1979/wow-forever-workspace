"""Stage an addon's TOC file list, keeping its metadata as committed.

  python tools/wowf/cli.py toc-stage ADDON [--dry-run]

While a release's metadata (## Version and the rest) waits for review, a code commit still needs the TOC lines
of its new Lua files. This writes into git's index the committed TOC's header (its ## lines, comments and blank
lines before the first file) followed by the working copy's file lines. The working copy is left alone, and
`git commit` then takes the file list without the new version. Header lines that differ are listed, so a
needed change (a new SavedVariables line) isn't left out unnoticed.

- ADDON is a workspace folder name, an absolute path, or `.` inside the addon's folder (as `package`)
- with no committed TOC (a new addon), the working copy is staged as it is
"""
import argparse
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import config  # noqa: E402
from package import resolve_addon  # noqa: E402


def split(text):
    """(header lines, body lines): the header runs until the first line that isn't a comment or blank."""
    lines = text.splitlines()
    for i, line in enumerate(lines):
        s = line.strip()
        if s and not s.startswith("#"):
            return lines[:i], lines[i:]
    return lines, []


def merge(committed, working):
    """The committed header with the working copy's file lines, ending in a newline when the working copy
    does; and the header lines that differ, each prefixed "-" (committed) or "+" (working copy)."""
    head, _ = split(committed)
    new_head, body = split(working)
    lines = head + body
    text = "\n".join(lines)
    if working.endswith("\n") and lines:
        text += "\n"
    differs = [f"- {line}" for line in head if line not in new_head]
    differs += [f"+ {line}" for line in new_head if line not in head]
    return text, differs


def _git(cwd, *args, data=None):
    return subprocess.run(["git", *args], cwd=cwd, input=data, capture_output=True, check=True).stdout


def main(argv):
    p = argparse.ArgumentParser(prog="wowf toc-stage")
    p.add_argument("addon")
    p.add_argument("--dry-run", action="store_true", help="print what would be staged; change nothing")
    a = p.parse_args(argv)
    root = None if os.path.isabs(a.addon) else config.load()["_root"]   # a folder name needs the workspace
    addon_dir = resolve_addon(a.addon, root)
    name = os.path.basename(addon_dir)
    path = os.path.join(addon_dir, name + ".toc")
    if not os.path.isfile(path):
        print(f"toc-stage: no {name}.toc in {addon_dir}")
        return 1
    top = _git(addon_dir, "rev-parse", "--show-toplevel").decode().strip()
    rel = os.path.relpath(path, top).replace(os.sep, "/")
    with open(path, encoding="utf-8") as f:
        working = f.read()
    try:
        committed = _git(top, "show", f"HEAD:{rel}").decode("utf-8")
    except subprocess.CalledProcessError:
        committed = None
    if committed is None:
        text, differs = working, []
        print(f"toc-stage: {rel} isn't committed yet; staging it as it is")
    else:
        text, differs = merge(committed, working)
    for line in differs:
        print(f"toc-stage: header kept as committed: {line}")
    if a.dry_run:
        print(text, end="")
        return 0
    blob = _git(top, "hash-object", "-w", "--stdin", "--path", rel, data=text.encode("utf-8")).decode().strip()
    _git(top, "update-index", "--add", "--cacheinfo", f"100644,{blob},{rel}")
    print(f"toc-stage: staged {rel}'s file list ({len(split(text)[1])} lines); its header as committed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
