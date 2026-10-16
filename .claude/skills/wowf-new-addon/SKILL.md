---
name: wowf-new-addon
description: Scaffold a new World of Warcraft Forever addon folder in the workspace with a 16001 TOC, namespace header, event dispatcher and message bus, SavedVariables defaults and forward-only migrations, combat-lockdown queue, secret-safe text helpers, and optional Blizzard Settings panel, slash commands, addon compartment entry, per-character data, locale file, a main window with the grey by-signature, a draggable minimap button, a custom icon, and per-addon CLAUDE.md plus settings for addon-folder sessions, then lint it clean. Use when asked to create, start, scaffold or bootstrap a new Forever addon, even if only a name and an idea are given.
argument-hint: "[AddonName] [features]"
allowed-tools: Bash(python "${CLAUDE_SKILL_DIR}/scripts/scaffold.py" *)
---

# wowf-new-addon

## 1. Gather (ask only for what's missing; propose sensible defaults)
- **Name:** becomes the folder, the TOC, the SV prefix and the global function prefix. Letters, digits and underscore; no spaces (e.g. `MusicForever`).
- **Title** shown in the AddOns list (keep it plain; the signature is added separately), and a one-line **Notes**.
- **Category:** free text in the AddOns list. Used so far: `Audio & Video` (MusicForever), `Auction & Economy` (BuffettForever). Others: Quests, Map, Inventory, Chat, User Interface, Professions, Collections, Development Tools, Miscellaneous.
- **Features** (default `options,slash,compartment,locales`; Justin's addons so far use all of them):
  - `options`: Blizzard Settings panel (Options > AddOns), with a signature header and a minimap checkbox when those are on;
  - `slash`: `/name` commands (with `window`, a plain `/name` opens the window);
  - `compartment`: minimap addon-compartment entry (left-click: window or toggle; right-click: options);
  - `chardb`: per-character SavedVariables (the window position is saved there when present);
  - `locales`: `Locales\enUS.lua` string table;
  - `window`: `UI\Widgets.lua` + `UI\MainFrame.lua`, a ButtonFrameTemplate window (title, Escape closes, saved position, built on first open, `ns.Main.Content` for your panes);
  - `minimap`: `UI\MinimapButton.lua`, a draggable minimap button without LibDBIcon (angle saved account-wide);
  - `claude`: `CLAUDE.md` for addon-only notes plus `.claude\settings.json` that grants `..`, so a session opened in the addon folder can read and edit the shared skills and tools (see the workspace CLAUDE.md).
- **Slash commands** (default: the lowercase name; several allowed, e.g. `bf,buffett`).
- **Signature** (Justin's addons: `Typheous`) and whether it has its own **icon**.

## 2. Scaffold
```
python "${CLAUDE_SKILL_DIR}/scripts/scaffold.py" <Name> --title "<Title>" --notes "<one line>" --category "<Category>" --slash <cmd>[,<alias>] --signature Typheous --icon --features options,slash,compartment,chardb,locales,window,minimap,claude [--dry-run]
```
It writes `<workspace>\<Name>\` and refuses to overwrite existing files.
- **TOC:** 16001, `Title: <Title> |cff9d9d9dby Typheous|r`, Author (default Typheous), IconTexture, SavedVariables, compartment globals, `X-Game: [Game]`.
- **Lua:** `Locales\enUS.lua`, `Core.lua`, `UI\Widgets.lua`, `UI\MainFrame.lua`, `UI\MinimapButton.lua`, `Options.lua`, `Slash.lua`, `Compartment.lua` (only the chosen features).
- **Docs:** `README.md` (with the `*by Typheous*` line), `CHANGELOG.md`, and with `claude` the addon `CLAUDE.md`.
- **Icon:** with `--icon` the TOC and minimap button point at `Media\Icon.tga`. Draw it with `python tools/wowf/cli.py make-icon --design <design> --out <Name>/Media/Icon.tga` (designs live in `tools/wowf/make_icon.py`: `note` for MusicForever, `coin` for BuffettForever; add a `render_<design>` for a new addon, keeping the family look: disc, gold rim, drop shadow). Always pass `--out` with `--size 512` (the CurseForge logo goes to `dist/`).

If the folder already exists but is empty, scaffolding into it is fine.

## 3. What the generated code gives you (build on it, don't rewrite it)
- `ns.Print(msg)`, `ns.L[...]`, and the bus `ns.On("MESSAGE", fn)` / `ns.Fire("MESSAGE", ...)` (`LOGIN`, `LOGOUT` and `MAIN_BUILT(frame, content)` are fired for you).
- `ns.IsSecret(v)` / `ns.SafeText(v, fallback)`: use these for anything from unit APIs.
- `ns.RunOutOfCombat(fn)`: queues protected-frame changes until `PLAYER_REGEN_ENABLED`.
- `ns.events` (handler table; add `function ns.events:EVENT_NAME(...)` and `ns.eventFrame:RegisterEvent("EVENT_NAME")`).
- `ns.db` (and `ns.charDB`) are ready after `ADDON_LOADED`. To add settings: add keys to `defaults`, bump `DB_VERSION`, and add a migration for old data. Never wipe.
- `ns.BuildOptions(db)` runs inside `ADDON_LOADED`. Add controls there (see `wowf-addon-dev` ui-patterns.md: checkbox, slider, dropdown).
- `ns.UI` builders (Button, Check, Slider, Input, Panel, TitledPanel, ScrollList, SetupRow, positions) and `ns.Main.Toggle/Show/Hide/IsShown/GetFrame`.
- MusicForever is the worked example of everything above at full size (tabs, lists, player bar, mini player).

## 4. Then
1. Lint with `wowf-review`. It must be clean.
2. Offer to deploy with `wowf-deploy`. A new folder needs a client restart and the addon enabled in the AddOns list.
3. Fill in the CHANGELOG "Tested on build:" line after the first in-game test.
4. Commit in the workspace repo. A shipped addon later moves to its own repo via `git subtree split`.
