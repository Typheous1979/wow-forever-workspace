---
name: wowf-new-addon
description: Scaffold a new World of Warcraft Forever addon folder in the workspace with a 16001 TOC, namespace header, event dispatcher, SavedVariables defaults and forward-only migrations, combat-lockdown queue, secret-safe text helpers, and optional Blizzard Settings panel, slash command, addon compartment entry, per-character data and locale file, then lint it clean. Use when asked to create, start, scaffold or bootstrap a new Forever addon, even if only a name and an idea are given.
argument-hint: "[AddonName] [features]"
allowed-tools: Bash(python "${CLAUDE_SKILL_DIR}/scripts/scaffold.py" *)
---

# wowf-new-addon

## 1. Gather (ask only for what's missing; propose sensible defaults)
- **Name:** becomes the folder, the TOC, the SV prefix and the global function prefix. Letters, digits and underscore; no spaces (e.g. `MusicForever`).
- **Title** shown in the AddOns list, and a one-line **Notes**.
- **Category:** use a standard one: Media (audio/art), Quests, Map, Inventory, Chat, User Interface, Professions, Collections, Development Tools, Miscellaneous.
- **Features** (default `options,slash,compartment,locales`):
  - `options`: Blizzard Settings panel (Options > AddOns);
  - `slash`: `/name` command with help, options and toggle;
  - `compartment`: minimap addon-compartment entry (left-click toggle, right-click options);
  - `chardb`: per-character SavedVariables in addition to the account-wide ones;
  - `locales`: `Locales\enUS.lua` string table.
- **Slash command** (default: the lowercase name).

## 2. Scaffold
```
python "${CLAUDE_SKILL_DIR}/scripts/scaffold.py" <Name> --title "<Title>" --notes "<one line>" --category Media --features options,slash,compartment,locales [--slash mf] [--dry-run]
```
It writes `<workspace>\<Name>\` and refuses to overwrite existing files.
- **TOC:** 16001, metadata, `X-Game: [Game]`.
- **Lua:** `Locales\enUS.lua`, `Core.lua`, `Options.lua`, `Slash.lua`, `Compartment.lua`.
- **Docs:** `README.md`, `CHANGELOG.md`.

If the folder already exists but is empty (like `MusicForever\`), scaffolding into it is fine.

## 3. What the generated code gives you (build on it, don't rewrite it)
- `ns.Print(msg)`, `ns.L[...]`.
- `ns.IsSecret(v)` / `ns.SafeText(v, fallback)`: use these for anything from unit APIs.
- `ns.RunOutOfCombat(fn)`: queues protected-frame changes until `PLAYER_REGEN_ENABLED`.
- `ns.events` (handler table; add `function ns.events:EVENT_NAME(...)` and `ns.eventFrame:RegisterEvent("EVENT_NAME")`).
- `ns.db` is ready after `ADDON_LOADED`. To add settings: add keys to `defaults`, bump `DB_VERSION`, and add a migration for old data. Never wipe.
- `ns.BuildOptions(db)` runs inside `ADDON_LOADED`. Add controls there (see `wowf-addon-dev` ui-patterns.md: checkbox, slider, dropdown).

## 4. Then
1. Lint with `wowf-review`. It must be clean.
2. Offer to deploy with `wowf-deploy`. A new folder needs a client restart and the addon enabled in the AddOns list.
3. Fill in the CHANGELOG "Tested on build:" line after the first in-game test.
4. Commit in the workspace repo. A shipped addon later moves to its own repo via `git subtree split`.
