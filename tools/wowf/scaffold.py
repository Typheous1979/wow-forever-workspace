"""Scaffold a new WoW Forever addon in the workspace.

  python tools/wowf/cli.py new NAME --title "My Addon" [--notes "..."] [--author Justin]
         [--category Media] [--slash ma] [--features options,slash,compartment,chardb,locales]
         [--dry-run]

Never overwrites existing files. Templates: .claude/skills/wowf-new-addon/assets/templates/.
"""
import argparse
import os
import re
import string

import config

ALL_FEATURES = ["options", "slash", "compartment", "chardb", "locales"]


def lua_str(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')


def render(tmpl_dir, name, mapping):
    with open(os.path.join(tmpl_dir, name), encoding="utf-8") as f:
        return string.Template(f.read()).substitute(mapping)


def build(root, name, title, notes, author, category, slash, features):
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{1,40}", name):
        raise SystemExit("name must be letters/digits/underscore, start with a letter (it becomes the folder, TOC and global prefix)")
    tmpl = os.path.join(root, ".claude", "skills", "wowf-new-addon", "assets", "templates")
    dest = os.path.join(root, name)
    upper = re.sub(r"[^A-Z0-9_]", "", name.upper())
    sv = f"{name}DB"
    chardb = f"{name}CharDB"
    m = {
        "NAME": name,
        "TITLE": lua_str(title),
        "UPPER": upper,
        "SLASH": (slash or name.lower()).lstrip("/"),
        "SVNAME": sv,
        "CHARDB_INIT": (f"    {chardb} = {chardb} or {{}}\n    ns.charDB = {chardb}\n" if "chardb" in features else ""),
    }
    files = {}
    toc = [
        "## Interface: 16001",
        f"## Title: {title}",
        f"## Notes: {notes}",
        f"## Author: {author}",
        "## Version: 0.1.0",
        f"## Category: {category}",
        "## IconTexture: Interface\\Icons\\INV_Misc_Note_01",
        f"## SavedVariables: {sv}",
    ]
    if "chardb" in features:
        toc.append(f"## SavedVariablesPerCharacter: {chardb}")
    if "compartment" in features:
        toc += [f"## AddonCompartmentFunc: {name}_OnAddonCompartmentClick",
                f"## AddonCompartmentFuncOnEnter: {name}_OnAddonCompartmentEnter",
                f"## AddonCompartmentFuncOnLeave: {name}_OnAddonCompartmentLeave"]
    toc += ["## X-Game: [Game]", "## X-Family: [Family]", ""]
    lua_order = []
    if "locales" in features:
        files["Locales\\enUS.lua"] = render(tmpl, "enUS.lua", m)
        lua_order.append("Locales\\enUS.lua")
    files["Core.lua"] = render(tmpl, "Core.lua", m)
    lua_order.append("Core.lua")
    if "options" in features:
        files["Options.lua"] = render(tmpl, "Options.lua", m)
        lua_order.append("Options.lua")
    if "slash" in features:
        files["Slash.lua"] = render(tmpl, "Slash.lua", m)
        lua_order.append("Slash.lua")
    if "compartment" in features:
        files["Compartment.lua"] = render(tmpl, "Compartment.lua", m)
        lua_order.append("Compartment.lua")
    files[f"{name}.toc"] = "\n".join(toc + lua_order) + "\n"
    files["README.md"] = (f"# {title}\n\n{notes}\n\nWoW Forever addon (interface 16001). Built in the wow-forever-workspace.\n\n"
                          f"- Slash: `/{m['SLASH']}`\n- SavedVariables: `{sv}`\n")
    files["CHANGELOG.md"] = "# Changelog\n\n## 0.1.0 (unreleased)\n- Scaffolded. Tested on build: (fill in)\n"
    return dest, files


def main(argv):
    p = argparse.ArgumentParser(prog="wowf new")
    p.add_argument("name")
    p.add_argument("--title")
    p.add_argument("--notes", default="A WoW Forever addon.")
    p.add_argument("--author", default="Justin")
    p.add_argument("--category", default="Miscellaneous")
    p.add_argument("--slash")
    p.add_argument("--features", default="options,slash,compartment,locales")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--root", help=argparse.SUPPRESS)
    a = p.parse_args(argv)
    root = a.root or config.load()["_root"]
    features = [f.strip() for f in a.features.split(",") if f.strip()]
    bad = [f for f in features if f not in ALL_FEATURES]
    if bad:
        raise SystemExit(f"unknown features {bad}; choose from {ALL_FEATURES}")
    dest, files = build(root, a.name, a.title or a.name, a.notes, a.author, a.category, a.slash, features)
    existing = [rel for rel in files if os.path.exists(os.path.join(dest, rel))]
    if existing:
        raise SystemExit(f"refusing to overwrite existing files in {dest}: {', '.join(existing)}")
    for rel, content in files.items():
        path = os.path.join(dest, rel)
        if a.dry_run:
            print(f"would write {path}")
            continue
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(content)
        print(f"wrote {os.path.relpath(path, root)}")
    if not a.dry_run:
        print(f"next: python tools/wowf/cli.py lint {a.name}   then deploy with wowf-deploy")
    return 0
