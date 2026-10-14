"""Read SavedVariables and addon enable state from a client's WTF folder (read-only).

  python tools/wowf/cli.py sv ADDON [--client beta] [--account ID] [--char NAME]
                                    [--bak] [--diff] [--path a.b.c] [--depth N] [--all] [--json]
  python tools/wowf/cli.py sv list ADDON      list every SV file for ADDON
  python tools/wowf/cli.py sv status ADDON    AddOns.txt state per character, SV files, deploy link

Never executes Lua; never writes to WTF. SavedVariables are written by the client
only on /reload or logout, so the file can lag what the game has in memory.
"""
import argparse
import datetime
import json
import os
import subprocess
import sys

import config
from lua_literal import parse_assignments, to_jsonable
from lua_lexer import LuaSyntaxError

MAX_DEPTH_SEARCH = 4


def _walk_limited(base, max_depth):
    base_depth = base.rstrip(os.sep).count(os.sep)
    for dirpath, dirnames, filenames in os.walk(base):
        if dirpath.count(os.sep) - base_depth >= max_depth:
            dirnames[:] = []
        yield dirpath, dirnames, filenames


def find_sv_files(client_dir, addon, bak=False):
    """Return [(scope, label, path)] for ADDON's SV files under WTF/Account."""
    acct_root = os.path.join(client_dir, "WTF", "Account")
    want = (addon + (".lua.bak" if bak else ".lua")).lower()
    out = []
    if not os.path.isdir(acct_root):
        return out
    for acct in sorted(os.listdir(acct_root)):
        adir = os.path.join(acct_root, acct)
        if not os.path.isdir(adir):
            continue
        for dirpath, _, files in _walk_limited(adir, MAX_DEPTH_SEARCH):
            if os.path.basename(dirpath).lower() != "savedvariables":
                continue
            for f in files:
                if f.lower() == want:
                    rel = os.path.relpath(dirpath, adir)
                    scope = "account" if rel.lower() == "savedvariables" else "character"
                    label = acct if scope == "account" else acct + "/" + os.path.dirname(rel).replace(os.sep, "/")
                    out.append((scope, label, os.path.join(dirpath, f)))
    return out


def find_addons_txt(client_dir):
    acct_root = os.path.join(client_dir, "WTF", "Account")
    out = []
    if not os.path.isdir(acct_root):
        return out
    for dirpath, _, files in _walk_limited(acct_root, MAX_DEPTH_SEARCH + 1):
        for f in files:
            if f.lower() == "addons.txt":
                out.append(os.path.join(dirpath, f))
    return out


def game_running():
    try:
        r = subprocess.run(["tasklist", "/FO", "CSV", "/NH"], capture_output=True, text=True, errors="replace")
    except OSError:
        return []
    names = set()
    for line in r.stdout.splitlines():
        exe = line.split(",")[0].strip('"')
        if exe.lower().startswith("wow") and exe.lower().endswith(".exe"):
            names.add(exe)
    return sorted(names)


def load_sv(path):
    with open(path, "rb") as f:
        return parse_assignments(f.read())


def select_path(value, dotted):
    for part in dotted.split("."):
        if isinstance(value, dict):
            key = part
            if key not in value:
                try:
                    key = int(part)
                except ValueError:
                    pass
            value = value.get(key)
        elif isinstance(value, list):
            try:
                value = value[int(part) - 1]
            except (ValueError, IndexError):
                return None
        else:
            return None
    return value


def pretty(v, depth=4, limit=50, indent=0):
    pad = "  " * indent
    if isinstance(v, dict):
        if depth == 0:
            return "{...%d keys}" % len(v)
        lines = ["{"]
        items = sorted(v.items(), key=lambda kv: (str(type(kv[0])), str(kv[0])))
        for i, (k, x) in enumerate(items):
            if limit and i >= limit:
                lines.append(f"{pad}  ... {len(items) - limit} more")
                break
            ks = f"[{k!r}]" if not isinstance(k, str) else k
            lines.append(f"{pad}  {ks} = {pretty(x, depth - 1, limit, indent + 1)}")
        lines.append(pad + "}")
        return "\n".join(lines)
    if isinstance(v, list):
        if depth == 0:
            return "{...%d items}" % len(v)
        if all(not isinstance(x, (dict, list)) for x in v) and len(v) <= 12:
            return "{ " + ", ".join(repr(x) for x in v) + " }"
        lines = ["{"]
        for i, x in enumerate(v):
            if limit and i >= limit:
                lines.append(f"{pad}  ... {len(v) - limit} more")
                break
            lines.append(f"{pad}  [{i + 1}] = {pretty(x, depth - 1, limit, indent + 1)}")
        lines.append(pad + "}")
        return "\n".join(lines)
    return repr(v)


def diff(a, b, prefix=""):
    out = []
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b), key=str):
            p = f"{prefix}.{k}" if prefix else str(k)
            if k not in a:
                out.append(f"+ {p} = {_short(b[k])}")
            elif k not in b:
                out.append(f"- {p} (was {_short(a[k])})")
            else:
                out += diff(a[k], b[k], p)
    elif isinstance(a, list) and isinstance(b, list):
        for i in range(max(len(a), len(b))):
            p = f"{prefix}[{i + 1}]"
            if i >= len(a):
                out.append(f"+ {p} = {_short(b[i])}")
            elif i >= len(b):
                out.append(f"- {p} (was {_short(a[i])})")
            else:
                out += diff(a[i], b[i], p)
    elif a != b:
        out.append(f"~ {prefix}: {_short(a)} -> {_short(b)}")
    return out


def _short(v):
    s = json.dumps(to_jsonable(v), ensure_ascii=False)
    return s if len(s) < 80 else s[:77] + "..."


def _mtime(path):
    return datetime.datetime.fromtimestamp(os.path.getmtime(path)).strftime("%Y-%m-%d %H:%M:%S")


def cmd_status(cfg, addon, which):
    import deploy
    for key, c in config.pick_clients(cfg, which).items():
        print(f"== client {key} ({c['build']})  {c['dir']}")
        print("   deploy: " + deploy.describe(os.path.join(c["addons"], addon)))
        for path in find_addons_txt(c["dir"]):
            rel = os.path.relpath(os.path.dirname(path), os.path.join(c["dir"], "WTF", "Account")).replace(os.sep, "/")
            state = "not listed"
            for line in open(path, encoding="utf-8", errors="replace"):
                name, _, val = line.partition(":")
                if name.strip().lower() == addon.lower():
                    state = val.strip()
            print(f"   AddOns.txt {rel}: {state}")
        files = find_sv_files(c["dir"], addon)
        if not files:
            print("   SavedVariables: none yet (written on first /reload or logout after the addon loads)")
        for scope, label, path in files:
            print(f"   SV {scope:<9} {label}: {_mtime(path)}  {os.path.getsize(path)} bytes")
    running = game_running()
    if running:
        print(f"note: {', '.join(running)} is running — files reflect the last /reload or logout.")
    return 0


def main(argv):
    if argv and argv[0] in ("status", "list"):
        action, argv = argv[0], argv[1:]
    else:
        action = "show"
    p = argparse.ArgumentParser(prog="wowf sv")
    p.add_argument("addon")
    p.add_argument("--client")
    p.add_argument("--account")
    p.add_argument("--char")
    p.add_argument("--bak", action="store_true", help="read the .lua.bak (previous save)")
    p.add_argument("--diff", action="store_true", help="diff .lua.bak -> .lua")
    p.add_argument("--path", help="dotted path inside the data, e.g. WowfProbeDB.runs.1.meta")
    p.add_argument("--depth", type=int, default=4)
    p.add_argument("--all", action="store_true", help="no per-level item limit")
    p.add_argument("--json", action="store_true")
    a = p.parse_args(argv)
    cfg = config.load()
    if action == "status":
        return cmd_status(cfg, a.addon, a.client)
    found = []
    for key, c in config.pick_clients(cfg, a.client).items():
        for scope, label, path in find_sv_files(c["dir"], a.addon, bak=a.bak and not a.diff):
            if a.account and not label.startswith(a.account):
                continue
            if a.char and a.char.lower() not in label.lower():
                continue
            found.append((key, scope, label, path))
    if action == "list":
        for key, scope, label, path in found:
            print(f"{key:<8} {scope:<9} {label}  {_mtime(path)}  {path}")
        return 0 if found else 1
    if not found:
        print(f"no SavedVariables file for {a.addon}. It is written on /reload or logout after the addon has loaded.")
        return 1
    running = game_running()
    rc = 0
    for key, scope, label, path in found:
        print(f"== {key} {scope} {label}  (written {_mtime(path)})")
        try:
            data = load_sv(path)
            if a.diff:
                bak = path + ".bak"
                if not os.path.isfile(bak):
                    print("   no .bak to diff against")
                    continue
                lines = diff(load_sv(bak), data)
                print("\n".join(lines) if lines else "   no changes since previous save")
                continue
        except LuaSyntaxError as e:
            print(f"   parse error: {e}")
            rc = 2
            continue
        if a.path:
            data = select_path(data, a.path)
        if a.json:
            print(json.dumps(to_jsonable(data), indent=2, ensure_ascii=False))
        else:
            print(pretty(data, a.depth, 0 if a.all else 50))
    if running:
        print(f"note: {', '.join(running)} is running — memory may be newer than these files.")
    return rc
