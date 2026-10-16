"""Scaffold a new WoW Forever addon in the workspace.

  python tools/wowf/cli.py new NAME --title "My Addon" [--notes "..."] [--author Typheous]
         [--category Miscellaneous] [--slash ma[,myaddon]] [--signature Typheous] [--icon]
         [--features options,slash,compartment,chardb,locales,window,minimap,claude]
         [--dry-run]

Features:
  options      Blizzard Settings panel (Options > AddOns)
  slash        /command with help (and window/minimap commands when those are on)
  compartment  addon-compartment entry (left: window or toggle, right: options)
  chardb       per-character SavedVariables (<Name>CharDB)
  locales      Locales\\enUS.lua string table
  window       UI\\Widgets.lua + UI\\MainFrame.lua: a ButtonFrameTemplate window with the
               title, Escape-to-close, a saved position and (with --signature) the grey
               "by <signature>" line under its bottom-right corner, built on first open
  minimap      UI\\MinimapButton.lua: a draggable minimap button (no LibDBIcon needed)
  claude       CLAUDE.md for addon-only notes, plus .claude\\settings.json granting the
               workspace root (..) so a session opened in the addon folder can read and
               edit the shared skills and tools

--signature NAME adds "|cff9d9d9dby NAME|r" to the TOC Title and the "by NAME" line to the
window, the minimap/compartment tooltips and the Settings header (keep --title plain).
--icon points IconTexture (and the minimap button) at Interface\\AddOns\\<Name>\\Media\\Icon.tga;
draw it with `make-icon --design <design>` (see make_icon.py).

Never overwrites existing files. Templates: .claude/skills/wowf-new-addon/assets/templates/.
"""
import argparse
import os
import re
import string

import config

ALL_FEATURES = ["options", "slash", "compartment", "chardb", "locales", "window", "minimap", "claude"]
DEFAULT_ICON = "Interface\\Icons\\INV_Misc_Note_01"


def lua_str(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')


def render(tmpl_dir, name, mapping):
    with open(os.path.join(tmpl_dir, name), encoding="utf-8") as f:
        return string.Template(f.read()).substitute(mapping)


def _core_fragments(name, features):
    chardb = f"{name}CharDB"
    window_store = "ns.charDB" if "chardb" in features else "ns.db"
    extra = ""
    if "minimap" in features:
        extra += "    minimap = { angle = 200, shown = true },   -- minimap button: degrees around the edge, visible\n"
    if "window" in features and "chardb" not in features:
        extra += "    window = {},   -- main window position\n"
    char_defaults = ""
    chardb_init = ""
    if "chardb" in features:
        body = "    window = {},   -- main window position (per character)\n" if "window" in features else ""
        char_defaults = "local charDefaults = {\n" + body + "}\n"
        chardb_init = (f"    {chardb} = {chardb} or {{}}\n"
                       f"    CopyDefaults(charDefaults, {chardb})\n"
                       f"    ns.charDB = {chardb}\n")
    init_calls = "    if ns.MinimapButton then ns.MinimapButton.Init() end\n" if "minimap" in features else ""
    return {
        "DEFAULTS_EXTRA": extra,
        "CHAR_DEFAULTS": char_defaults,
        "CHARDB_INIT": chardb_init,
        "INIT_CALLS": init_calls,
        "WINDOW_STORE": window_store,
    }


def build(root, name, title, notes, author, category, slash, features, signature=None, icon=False):
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{1,40}", name):
        raise SystemExit("name must be letters/digits/underscore, start with a letter (it becomes the folder, TOC and global prefix)")
    tmpl = os.path.join(root, ".claude", "skills", "wowf-new-addon", "assets", "templates")
    dest = os.path.join(root, name)
    upper = re.sub(r"[^A-Z0-9_]", "", name.upper())
    sv = f"{name}DB"
    chardb = f"{name}CharDB"
    aliases = [s.strip().lstrip("/") for s in (slash or name.lower()).split(",") if s.strip()]
    icon_path = f"Interface\\AddOns\\{name}\\Media\\Icon.tga" if icon else DEFAULT_ICON
    sig_key = f"by {signature}" if signature else ""
    m = {
        "NAME": name,
        "TITLE": lua_str(title),
        "NOTES": notes,
        "UPPER": upper,
        "SLASH": aliases[0],
        "SLASH_LINES": "\n".join(f'SLASH_{upper}{i} = "/{a}"' for i, a in enumerate(aliases, 1)),
        "SVNAME": sv,
        "ICON_LUA": lua_str(icon_path),
        "SIGNATURE_KEY": lua_str(sig_key),
        "WINDOW_SIGNATURE": (
            '    local signature = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")\n'
            '    signature:SetPoint("TOPRIGHT", frame, "BOTTOMRIGHT", -12, -6)\n'
            f'    signature:SetText(ns.L["{lua_str(sig_key)}"])\n' if signature else ""),
        "TOOLTIP_SIGNATURE": (f'    GameTooltip:AddLine(ns.L["{lua_str(sig_key)}"], 0.62, 0.62, 0.62)\n' if signature else ""),
        "OPTIONS_HEADER": (
            '    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(\n'
            f'        "{lua_str(title)} |cff9d9d9d" .. L["{lua_str(sig_key)}"] .. "|r"))\n' if signature else ""),
        "OPTIONS_MINIMAP": (
            f'    local minimap = Settings.RegisterAddOnSetting(category, "{name}_MinimapShown", "shown", db.minimap,\n'
            '        type(true), L["Show minimap button"], true)\n'
            f'    Settings.CreateCheckbox(category, minimap, L["The {lua_str(title)} button on the minimap."])\n'
            '    minimap:SetValueChangedCallback(function(_, value) ns.MinimapButton.SetShown(value) end)\n'
            if "minimap" in features else ""),
        "SLASH_MINIMAP": (
            '    elseif cmd == "minimap" then\n'
            '        ns.MinimapButton.Toggle()\n' if "minimap" in features else ""),
        "SLASH_MINIMAP_HELP": (" | minimap" if "minimap" in features else ""),
    }
    m.update(_core_fragments(name, features))
    files = {}
    toc_title = f"{title} |cff9d9d9d{sig_key}|r" if signature else title
    toc = [
        "## Interface: 16001",
        f"## Title: {toc_title}",
        f"## Notes: {notes}",
        f"## Author: {author}",
        "## Version: 0.1.0",
        f"## Category: {category}",
        f"## IconTexture: {icon_path}",
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

    def add(rel, template):
        files[rel] = render(tmpl, template, m)
        lua_order.append(rel)

    if "locales" in features:
        add("Locales\\enUS.lua", "enUS.lua")
    add("Core.lua", "Core.lua")
    if "window" in features:
        add("UI\\Widgets.lua", "Widgets.lua")
        add("UI\\MainFrame.lua", "MainFrame.lua")
    if "minimap" in features:
        add("UI\\MinimapButton.lua", "MinimapButton.lua")
    if "options" in features:
        add("Options.lua", "Options.lua")
    if "slash" in features:
        add("Slash.lua", "Slash_window.lua" if "window" in features else "Slash.lua")
    if "compartment" in features:
        add("Compartment.lua", "Compartment_window.lua" if "window" in features else "Compartment.lua")
    files[f"{name}.toc"] = "\n".join(toc + lua_order) + "\n"
    if "claude" in features:
        files["CLAUDE.md"] = render(tmpl, "CLAUDE.md.tmpl", m)
        files[".claude\\settings.json"] = render(tmpl, "settings.json.tmpl", m)
    byline = f"*by {signature}*\n\n" if signature else ""
    slashes = ", ".join(f"`/{a}`" for a in aliases)
    files["README.md"] = (f"# {title}\n\n{byline}{notes}\n\nWoW Forever addon (interface 16001). Built in the wow-forever-workspace.\n\n"
                          f"- Slash: {slashes}\n- SavedVariables: `{sv}`\n")
    files["CHANGELOG.md"] = "# Changelog\n\n## 0.1.0 (unreleased)\n- Scaffolded. Tested on build: (fill in)\n"
    return dest, files


def main(argv):
    p = argparse.ArgumentParser(prog="wowf new")
    p.add_argument("name")
    p.add_argument("--title")
    p.add_argument("--notes", default="A WoW Forever addon.")
    p.add_argument("--author", default="Typheous")
    p.add_argument("--category", default="Miscellaneous")
    p.add_argument("--slash", help="command(s) without the slash, comma-separated: bf,buffett")
    p.add_argument("--signature", help='adds the grey "by NAME" signature (TOC title, window, tooltips)')
    p.add_argument("--icon", action="store_true", help="IconTexture = Interface\\AddOns\\<Name>\\Media\\Icon.tga")
    p.add_argument("--features", default="options,slash,compartment,locales")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--root", help=argparse.SUPPRESS)
    a = p.parse_args(argv)
    root = a.root or config.load()["_root"]
    features = [f.strip() for f in a.features.split(",") if f.strip()]
    bad = [f for f in features if f not in ALL_FEATURES]
    if bad:
        raise SystemExit(f"unknown features {bad}; choose from {ALL_FEATURES}")
    dest, files = build(root, a.name, a.title or a.name, a.notes, a.author, a.category, a.slash, features,
                        signature=a.signature, icon=a.icon)
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
        if a.icon:
            print(f"next: python tools/wowf/cli.py make-icon --design <design> --out {a.name}/Media/Icon.tga")
        print(f"next: python tools/wowf/cli.py lint {a.name}   then deploy with wowf-deploy")
    return 0
