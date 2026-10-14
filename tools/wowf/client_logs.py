"""Client-side evidence: crash reports, taint log, client logs (read-only).

  python tools/wowf/cli.py logs crash [--client beta] [--last N]   summarize Errors\\*.txt crash reports
  python tools/wowf/cli.py logs taint [--grep ADDON] [--tail N]     Logs\\taint.log (enable: /console taintLog 1)
  python tools/wowf/cli.py logs show NAME [--grep TEXT] [--tail N]  any Logs\\NAME.log (Sound, General, Client, ...)
  python tools/wowf/cli.py logs list                                list log files with sizes and times
"""
import argparse
import datetime
import glob
import os
import re

import config

CRASH_KEYS = ["Version", "Exception.WowProject", "Exception.IssueType", "Exception.Summary:", "Exception.Assertion:",
              "Addons.Current", "Addons.Current.Function", "Addons.HasAny.Loaded", "LuaErrors"]


def _mtime(p):
    return datetime.datetime.fromtimestamp(os.path.getmtime(p)).strftime("%Y-%m-%d %H:%M")


def parse_crash(path):
    info = {}
    lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    for i, line in enumerate(lines):
        m = re.match(r"^<([^>]+)>\s*(.*)$", line)
        if m and m.group(1) in CRASH_KEYS:
            val = m.group(2).strip()
            if not val and i + 1 < len(lines) and not lines[i + 1].startswith("<"):
                val = lines[i + 1].strip()
            info[m.group(1)] = val
    return info


def cmd_crash(c, last):
    files = sorted(glob.glob(os.path.join(c["dir"], "Errors", "*.txt")), key=os.path.getmtime, reverse=True)[:last]
    if not files:
        print("no crash reports")
        return 0
    for f in files:
        info = parse_crash(f)
        print(f"== {os.path.basename(f)}  ({_mtime(f)})")
        for k in CRASH_KEYS:
            if info.get(k):
                print(f"   {k}: {info[k]}")
    print("hint: a crash with Addons.Current set (or right after an addon call) can be a documented API that "
          "access-violates — pcall cannot catch it. Record it in forever-facts.md and index.CRASHES.")
    return 0


def tail(path, n, pattern=None):
    rx = re.compile(pattern, re.I) if pattern else None
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = [l.rstrip("\n") for l in f if rx is None or rx.search(l)]
    return lines[-n:]


def main(argv):
    p = argparse.ArgumentParser(prog="wowf logs")
    p.add_argument("action", choices=["crash", "taint", "show", "list"])
    p.add_argument("name", nargs="?")
    p.add_argument("--client", default="beta")
    p.add_argument("--grep")
    p.add_argument("--tail", type=int, default=60)
    p.add_argument("--last", type=int, default=3)
    a = p.parse_args(argv)
    cfg = config.load()
    for key, c in config.pick_clients(cfg, a.client).items():
        logs = os.path.join(c["dir"], "Logs")
        if a.action == "crash":
            cmd_crash(c, a.last)
        elif a.action == "list":
            for f in sorted(glob.glob(os.path.join(logs, "*.log"))):
                print(f"{os.path.basename(f):<28} {os.path.getsize(f):>9}  {_mtime(f)}")
        elif a.action == "taint":
            path = os.path.join(logs, "taint.log")
            if not os.path.isfile(path):
                print("no taint.log. In game: /console taintLog 1 (or 2 for verbose), reproduce, then /reload or log out.")
                continue
            print("\n".join(tail(path, a.tail, a.grep)))
        else:
            if not a.name:
                p.error("show needs a log NAME, e.g. Sound")
            name = a.name if a.name.lower().endswith(".log") else a.name + ".log"
            path = os.path.join(logs, name)
            if not os.path.isfile(path):
                print(f"no {path}")
                continue
            print("\n".join(tail(path, a.tail, a.grep)))
    return 0
