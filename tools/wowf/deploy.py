"""Deploy workspace addons into Forever client AddOns folders.

  python tools/wowf/cli.py deploy ADDON [--client beta|forever|all] [--mode junction|copy]
  python tools/wowf/cli.py deploy ADDON --remove [--client ...]
  python tools/wowf/cli.py deploy --status
  python tools/wowf/cli.py deploy --prune            remove dangling junctions that point into this repo

Safety:
  * Junction mode (default) links <client>\\Interface\\AddOns\\ADDON -> <repo>\\ADDON; edits are live
    after /reload. A brand-new addon folder may need a full client restart to be noticed.
  * Never replaces a real folder (e.g. a CurseForge install) unless --replace-copy --yes, which MOVES
    it to <client>\\Interface\\AddOns.wowf-backup\\ first.
  * Removal only unlinks junctions that point into this repo (os.rmdir on a junction removes the
    link, never the target). Copy-mode folders are only removed if they carry our .wowf-deployed marker.
  * NEVER delete a deployed folder with Remove-Item -Recurse / rmdir /s / Explorer: through a junction
    that deletes the source files in OneDrive.
"""
import argparse
import datetime
import os
import shutil
import stat
import subprocess
import sys

import config
from toc import addon_tocs

MARKER = ".wowf-deployed"
FILE_ATTRIBUTE_OFFLINE = 0x1000
FILE_ATTRIBUTE_RECALL_ON_OPEN = 0x40000
FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS = 0x400000
SPECIAL_SOURCES = {"wowfprobe": os.path.join(".claude", "skills", "wowf-debug", "assets", "WowfProbe")}


def _norm(p):
    p = str(p)
    for pre in ("\\\\?\\", "\\??\\"):
        if p.startswith(pre):
            p = p[len(pre):]
    return os.path.normcase(os.path.abspath(p))


def _inside(child, parent):
    c, p = _norm(child), _norm(parent)
    return c == p or c.startswith(p.rstrip("\\/") + os.sep)


def junction_target(path):
    if not os.path.isjunction(path):
        return None
    try:
        return _norm(os.readlink(path))
    except OSError:
        return None


def source_dir(root, addon):
    if os.path.isdir(addon):
        return os.path.abspath(addon)
    special = SPECIAL_SOURCES.get(addon.lower())
    if special:
        return os.path.join(root, special)
    return os.path.join(root, addon)


def validate_source(root, src):
    if not os.path.isdir(src):
        raise SystemExit(f"deploy: no addon folder {src}")
    if not _inside(src, root):
        raise SystemExit(f"deploy: {src} is outside the workspace repo")
    folder, tocs = addon_tocs(src)
    if not tocs:
        raise SystemExit(f"deploy: {folder} has no .toc file")
    if not any(t.name == folder or t.name.startswith(folder + "_") or t.name.startswith(folder + "-") for t in tocs):
        raise SystemExit(f"deploy: no TOC named {folder}.toc (folder name and TOC name must match)")
    return folder


def describe(link):
    if not os.path.lexists(link):
        return "not deployed"
    if os.path.isjunction(link):
        tgt = junction_target(link)
        if tgt and not os.path.exists(tgt):
            return f"DANGLING junction -> {tgt}"
        return f"junction -> {tgt}"
    if os.path.isdir(link):
        if os.path.isfile(os.path.join(link, MARKER)):
            return "copy (deployed by wowf)"
        return "real folder (not managed by wowf)"
    return "unexpected file"


def dehydrated_files(src, limit=5):
    bad = []
    for dirpath, _, files in os.walk(src):
        for f in files:
            try:
                attrs = os.stat(os.path.join(dirpath, f)).st_file_attributes
            except (OSError, AttributeError):
                continue
            if attrs & (FILE_ATTRIBUTE_OFFLINE | FILE_ATTRIBUTE_RECALL_ON_OPEN | FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS):
                bad.append(os.path.join(dirpath, f))
                if len(bad) >= limit:
                    return bad
    return bad


def make_junction(link, target):
    r = subprocess.run(["cmd", "/c", "mklink", "/J", link, target], capture_output=True, text=True, errors="replace")
    if r.returncode != 0 or not os.path.isjunction(link):
        raise SystemExit(f"deploy: mklink failed: {r.stdout.strip()} {r.stderr.strip()}")


def remove_link(link, root):
    """Remove a deployment we own. Returns a message."""
    if not os.path.lexists(link):
        return "nothing to remove"
    if os.path.isjunction(link):
        tgt = junction_target(link)
        if tgt is None or not _inside(tgt, root):
            raise SystemExit(f"deploy: refusing to remove junction {link} -> {tgt} (not into this repo)")
        os.rmdir(link)  # removes the link only
        return f"unlinked (source untouched: {tgt})"
    if os.path.isdir(link):
        if not os.path.isfile(os.path.join(link, MARKER)):
            raise SystemExit(f"deploy: refusing to remove real folder {link} (no {MARKER} marker)")
        for dirpath, dirnames, _ in os.walk(link):
            for d in dirnames:
                if os.path.isjunction(os.path.join(dirpath, d)) or os.path.islink(os.path.join(dirpath, d)):
                    raise SystemExit(f"deploy: refusing to remove {link}: contains a link")
        shutil.rmtree(link)
        return "removed copy"
    raise SystemExit(f"deploy: refusing to touch {link}")


def deploy_one(root, src, folder, client, mode, replace_copy, yes):
    addons = client["addons"]
    if not os.path.isdir(addons):
        raise SystemExit(f"deploy: {addons} does not exist")
    link = os.path.join(addons, folder)
    if os.path.lexists(link):
        if os.path.isjunction(link):
            tgt = junction_target(link)
            if tgt == _norm(src) and mode == "junction":
                return f"already linked -> {tgt}"
            if tgt and _inside(tgt, root):
                os.rmdir(link)
            else:
                raise SystemExit(f"deploy: {link} is a junction to {tgt}; remove it yourself if intended")
        elif os.path.isdir(link):
            if os.path.isfile(os.path.join(link, MARKER)):
                remove_link(link, root)
            elif replace_copy and yes:
                bdir = os.path.join(os.path.dirname(addons), "AddOns.wowf-backup")
                os.makedirs(bdir, exist_ok=True)
                dest = os.path.join(bdir, f"{folder}-{datetime.datetime.now():%Y%m%d-%H%M%S}")
                shutil.move(link, dest)
                print(f"moved existing folder to {dest}")
            else:
                raise SystemExit(f"deploy: {link} is a real folder (an installed copy?). Refusing to replace it.\n"
                                 f"Re-run with --replace-copy --yes to move it to AddOns.wowf-backup\\ first.")
        else:
            raise SystemExit(f"deploy: {link} exists and is not a folder")
    if mode == "junction":
        make_junction(link, src)
        return f"linked {link} -> {src}"
    shutil.copytree(src, link, ignore=shutil.ignore_patterns(".git", ".claude", "tests", "*.md", MARKER))
    with open(os.path.join(link, MARKER), "w") as fh:
        fh.write(src + "\n")
    return f"copied to {link}"


def status(cfg):
    root = cfg["_root"]
    clients = config.discover_clients(cfg)
    if not clients:
        print("no Forever clients found (check client_search_roots in wowf.config.json / wowf.local.json)")
        return 1
    for key, c in clients.items():
        print(f"== {key}: {c['dir']}  build {c['build']}")
        if not os.path.isdir(c["addons"]):
            print("   (no Interface\\AddOns yet)")
            continue
        n = 0
        for name in sorted(os.listdir(c["addons"])):
            p = os.path.join(c["addons"], name)
            d = describe(p)
            if d.startswith(("junction", "DANGLING", "copy (deployed by wowf)")):
                tgt = junction_target(p)
                ours = "" if tgt is None else ("  [workspace]" if _inside(tgt, root) else "  [elsewhere]")
                print(f"   {name}: {d}{ours}")
                n += 1
        print(f"   {n} managed link(s)")
    return 0


def main(argv):
    p = argparse.ArgumentParser(prog="wowf deploy", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("addon", nargs="?")
    p.add_argument("--client", default="beta", help="beta | forever | all (default beta)")
    p.add_argument("--mode", choices=["junction", "copy"], default="junction")
    p.add_argument("--remove", action="store_true")
    p.add_argument("--status", action="store_true")
    p.add_argument("--prune", action="store_true")
    p.add_argument("--replace-copy", action="store_true")
    p.add_argument("--yes", action="store_true")
    a = p.parse_args(argv)
    cfg = config.load()
    root = cfg["_root"]
    if a.status:
        return status(cfg)
    if a.prune:
        for key, c in config.discover_clients(cfg).items():
            if not os.path.isdir(c["addons"]):
                continue
            for name in os.listdir(c["addons"]):
                link = os.path.join(c["addons"], name)
                tgt = junction_target(link)
                if tgt and not os.path.exists(tgt) and _inside(tgt, root):
                    os.rmdir(link)
                    print(f"pruned dangling {key}:{name}")
        return 0
    if not a.addon:
        p.error("ADDON required")
    src = source_dir(root, a.addon)
    clients = config.pick_clients(cfg, a.client)
    if a.remove:
        folder = os.path.basename(os.path.normpath(src))
        for key, c in clients.items():
            print(f"{key}: {remove_link(os.path.join(c['addons'], folder), root)}")
        return 0
    folder = validate_source(root, src)
    hydr = dehydrated_files(src)
    if hydr:
        print("WARNING: some source files are OneDrive online-only; pin the AddOns folder "
              "('Always keep on this device'):\n  " + "\n  ".join(hydr))
    for key, c in clients.items():
        print(f"{key}: {deploy_one(root, src, folder, c, a.mode, a.replace_copy, a.yes)}")
    print("next: restart the client if this addon is new to it (new folders may need a restart; "
          "/reload is enough for code edits). Enable it in the AddOns list if needed.")
    return 0
