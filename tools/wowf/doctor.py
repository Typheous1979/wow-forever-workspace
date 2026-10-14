"""Environment check: python doctor.

  python tools/wowf/cli.py doctor
"""
import os
import shutil
import subprocess
import sys

import config
import index as idx


def line(ok, msg):
    print(("  OK   " if ok is True else "  WARN " if ok is None else "  FAIL ") + msg)


def main(argv):
    cfg = config.load()
    root = cfg["_root"]
    print(f"workspace: {root}")
    line(sys.version_info >= (3, 12), f"python {sys.version.split()[0]} (need 3.12+ for os.path.isjunction)")
    git = shutil.which("git")
    line(bool(git), f"git: {git}")
    if git:
        r = subprocess.run(["git", "config", "user.email"], cwd=root, capture_output=True, text=True)
        line(bool(r.stdout.strip()) or None, f"git user.email: {r.stdout.strip() or '(unset)'}")
    lc = os.path.join(root, "tools", "luacheck.exe")
    line(os.path.isfile(lc) or None, f"luacheck: {lc if os.path.isfile(lc) else 'missing — run: python tools/wowf/setup_luacheck.py'}")
    I = idx.Index(root)
    line(I.loaded or None, f"API index: build {I.meta.get('build')} ({len(I.docs)} doc records, {len(I.fx)} FrameXML)")
    line(bool(I.rt_meta) or None, f"runtime probe layer: {I.rt_meta.get('build') or 'none yet (deploy WowfProbe and run /wowfprobe)'}")
    up = os.path.isdir(config.UPSTREAM_DIR)
    line(up or None, f"upstream cache: {config.UPSTREAM_DIR if up else 'missing — run: cli.py api update'}")
    clients = config.discover_clients(cfg)
    line(bool(clients) or None, f"clients found: {', '.join(clients) or 'none'}")
    for key, c in clients.items():
        print(f"         {key}: {c['dir']}  build {c['build']}")
        if I.meta.get("build") and c["build"] and c["build"] != I.meta.get("build"):
            line(None, f"{key} client build {c['build']} differs from index build {I.meta.get('build')} — facts may skew; consider /wowf-refresh")
    if "forever" not in clients:
        line(None, "no _forever_ client yet (stress test Oct 19 / launch Nov 4 install it)")
    # OneDrive dehydration check on the workspace
    import deploy
    bad = []
    for d in os.listdir(root):
        p = os.path.join(root, d)
        if os.path.isdir(p) and not d.startswith("."):
            bad += deploy.dehydrated_files(p, limit=3)
    line(not bad or None, "OneDrive files available offline" + ("" if not bad else f" — online-only files found, e.g. {bad[0]}; right-click AddOns > Always keep on this device"))
    return 0
