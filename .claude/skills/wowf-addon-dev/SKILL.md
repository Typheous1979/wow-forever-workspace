---
name: wowf-addon-dev
description: Core knowledge for World of Warcraft Forever addons (game type Camelot/forever, TOC Interface 16001, Mainline 12.1.5 API with Midnight secret values and no combat log). Golden rules, TOC format, Lua 5.1 environment, SavedVariables lifecycle, secret values, protected and restricted calls, Settings panel, addon compartment, slash commands, audio and music APIs, and porting Midnight or Classic addons. Use whenever writing, editing, planning, reviewing or porting WoW Forever addon Lua, TOC or XML, or answering how Forever addons work, even if the user just says WoW addon.
when_to_use: Forever, Camelot, 16001, WOW_PROJECT_CAMELOT, wow forever addon, make X work on Forever, port to Forever, MusicForever
---

# WoW Forever addon development

**Facts as of 2026-10-14.** Beta server 1.60.1.70374, Justin's installed client 70338, `wowf` stress-test/launch product 70245. Facts drift between beta builds. Each one carries a status tag and a build; see `references/forever-facts.md` (IDs like [F-012]). When the build in front of you is newer than these facts, suggest `/wowf-refresh`.

**What Forever is:** the original Azeroth (cap 60, new zones and races) running the **modern Mainline UI and API, 12.1.5 family**, as the game type **Camelot** (TOC alias `forever`). Midnight's addon disarmament is fully active: **secret values**, **no combat log**, and protected calls that fail silently. Forever is NOT Classic Era. Classic tutorials, Classic WeakAuras and most AI training data are wrong for it.

**How far to trust a fact:** [Probe] measured in the client > [Source] Blizzard forever-branch UI source > [Wiki] Warcraft Wiki (Mainline docs) > [Community] reports > [Unverified]. Documented ≠ present: about 27 documented namespaces are absent at runtime, and at least one documented call crashes the client.

## The 15 golden rules

1. **TOC Interface 16001** (beta and test). Multi-client: list it comma-separated (`## Interface: 120100, 16001`), or ship a `<Name>_Camelot.toc`. See `references/toc-format.md`.
2. **Lua 5.1** plus WoW libraries. Not allowed: `goto`, `::labels::`, `//`, bitwise operators (use `bit.band`…), `_ENV`, `require`/`dofile`/`loadfile`, `io`, and `os` beyond `time/date/clock/difftime`. Forever-only `import` exists (70291+) but can't load files; don't depend on it. The TOC is the module loader.
3. **Mainline C_ APIs, not Classic globals.** `GetSpellInfo`, `GetItemInfo`, `UnitAura`, `GetAddOnMetadata` and about 50 others are gone; see `references/api-migration.md`. Uncached lookups return nil: request the load, then handle `*_DATA_LOAD_RESULT`.
4. **Namespace everything.** Every Lua file starts with `local addonName, ns = ...`. The only globals are SavedVariables, `SLASH_*` and compartment callbacks. Name frames after the addon or pass `nil`.
5. **One event frame plus a handler table** (`events[event](self, ...)`). Use `RegisterUnitEvent` for the player. Use `C_Timer` instead of OnUpdate polling.
6. **No combat log.** Registering `COMBAT_LOG_EVENT_UNFILTERED` errors and `CombatLog*` are gone. Don't rebuild Blizzard built-ins: damage meter, cooldown manager, swing timer, click-cast bindings, mouseover cast. See `references/what-to-build.md`.
7. **Secrets are drawn, not solved.** `UnitHealth` is always secret; names and identity are secret when restricted. Never do math, comparisons, `#`, table keys or (on Forever) `print` with them. Guard with `issecretvalue(v)`. Feed them to widgets: `StatusBar:SetMinMaxValues/SetValue`, `FontString:SetText`. See `references/secret-values.md`.
8. **Detect Forever** with `WOW_PROJECT_CAMELOT ~= nil and WOW_PROJECT_ID == WOW_PROJECT_CAMELOT` (18 since 70170), or the interface range 16000–19999, plus a `type()` probe for each feature's API. Never branch to Classic on `WOW_PROJECT_ID` alone.
9. **Secure snippets.** Believed working since 70009, when the restricted environment was fixed. `type(loadstring_untainted) == "nil"` is normal and proves nothing. Retest with a real snippet. Never write secure attributes onto Blizzard frames; use your own buttons.
10. **SavedVariables** load *after* your files run. Touch them only in `ADDON_LOADED` for your addon. Merge defaults and migrate forward; never wipe on a schema mismatch. They're written only at `/reload` or logout and can't hold secrets. See `references/lifecycle-and-savedvariables.md`.
11. **Combat lockdown.** Check `InCombatLockdown()` before you show, hide, move or change attributes on protected frames. Queue the closure for `PLAYER_REGEN_ENABLED`.
12. **Silent failures.** Protected calls such as `ChatFrame_OpenChat`, `C_SuperTrack.SetSuperTrackedUserWaypoint` and `SetRaidTarget` fail with no Lua error, and `pcall` doesn't help. Watch for "Interface action failed because of an AddOn". See `references/protected-and-restricted.md`.
13. **A nil-guard is not a crash-guard.** `if C_Foo and C_Foo.Bar` doesn't stop an access violation (e.g. `C_Housing.GetMaxHouseLevel`). Only call APIs verified on this build: run `wowf-api`, then use WowfProbe.
14. **Two-part names.** Names are "First Surname", unique per region. On 70009+, `UnitFullName("player")` returns first name and surname, not name and realm. Don't key data on name-realm strings.
15. **Skin and inform.** Never automate combat decisions, and don't replace Blizzard unit frames, the damage meter or the cooldown manager.

## Workflow for any code change

1. Read the relevant reference below. For any API not already named in these files, **verify it with the `wowf-api` skill** (`python tools/wowf/cli.py api show NAME`). If nothing knows the name, say so and give a safe probe: `/run print(type(C_X and C_X.Fn))`.
2. Emit **whole files**: the TOC plus every Lua file. Name the folder exactly like the TOC.
3. Lint with `python tools/wowf/cli.py lint <Addon>` (the `wowf-review` skill). Fix errors and explain any remaining warnings.
4. Deploy with `wowf-deploy`, then test in game with `wowf-debug`. Record which build a behaviour was observed on.
5. Write files with the Write/Edit tools, never PowerShell redirection, which adds a BOM.

## Porting (Midnight, retail or Classic → Forever)

Read `references/porting.md`. It covers:
- **License check first.**
- **The feasibility gate:** decline CLEU meters and boss mods, health math, combat aura logic, and secure snippets on Blizzard frames.
- **From Midnight:** add 16001 or `_Camelot.toc`, fix project-ID branches, and split "modern API" from "retail content".
- **From Classic:** move to the C_ APIs, drop CLEU, play sounds by FileDataID or SOUNDKIT, and fix name keys.

## References (read the one you need)

| File | Read when |
|---|---|
| `references/forever-facts.md` | You need a build-specific fact, a date or a status; to check whether something is confirmed |
| `references/toc-format.md` | Writing or fixing a .toc, multi-client packaging, game-type conditions |
| `references/lua-environment.md` | Which Lua and WoW library functions exist (string/table/math helpers, bit, import) |
| `references/lifecycle-and-savedvariables.md` | Load order, events at login and logout, SavedVariables patterns and migrations |
| `references/secret-values.md` | Anything touching unit data, health, names, auras, cooldowns, chat in instances |
| `references/api-migration.md` | Replacing a removed global; async spell and item data; waypoints; game rules; nameplates; menus |
| `references/ui-patterns.md` | Frames, backdrop, movable panels, Settings panel, addon compartment, slash commands, popups, tooltips, localization |
| `references/protected-and-restricted.md` | Taint, protected or forbidden calls, combat lockdown, addon messages and chat limits |
| `references/audio.md` | Sounds, music, SOUNDKIT, FileDataIDs, shipping .ogg/.mp3, sound CVars, zone, day/night and weather triggers |
| `references/porting.md` | Bringing an existing addon to Forever |
| `references/what-to-build.md` | Deciding whether a feature is allowed, useful, or already built in |
| `references/sources.md` | Where facts come from and how to re-fetch them |
