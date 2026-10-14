# Porting an existing addon to WoW Forever

## 0. License first
Read the LICENSE and the TOC `X-License`.
- **All Rights Reserved, or no license at all:** don't fork, copy or derive. You may only observe its behaviour. Some authors (e.g. Auctionator) explicitly forbid use as a reference.
- **MIT/BSD/GPL:** keep the notices; GPL code makes your addon GPL.

## 1. Feasibility gate: decline or redesign if the core needs
- `COMBAT_LOG_EVENT_UNFILTERED` / `CombatLogGetCurrentEventInfo` (meters, boss mods, proc trackers) → gone [F-070]. Blizzard ships the damage meter and cooldown manager.
- Arithmetic or comparisons on health, power or names → secrets [F-041]. Redesign as widget display.
- Reading auras or cooldowns to drive combat decisions → secret in restricted states.
- Secure snippets or attributes on **Blizzard** frames, or rebuilding click-casting → Forever has native click-cast and mouseover cast.
- Automating combat, chat, markers (`SetRaidTarget`) or casting → forbidden or protected [F-051].

Say clearly which feature can't survive, and port the rest.

## 2. From Midnight / retail (closest; start from the Midnight build, never the Classic branch)
1. TOC: add `16001` to `## Interface`, or ship `<Name>_Camelot.toc`. Check inline `[AllowLoadGameType ...]` lines: `mainline` includes camelot, `standard` excludes it [F-021].
2. Branches:
   - **project ID:** replace `WOW_PROJECT_ID == WOW_PROJECT_MAINLINE` with the explicit check below, because Forever is 18, not 1 [F-010]:
     ```lua
     local isForever = WOW_PROJECT_CAMELOT ~= nil and WOW_PROJECT_ID == WOW_PROJECT_CAMELOT
     local isRetail  = WOW_PROJECT_ID == WOW_PROJECT_MAINLINE
     ```
   - **IsRetail flags:** split one `IsRetail` into `UsesModernAPI` (true on Forever) and `HasRetailContent` (false: no M+, Delves, Housing, Encounter Journal) [F-038].
3. Re-test every secret path on Forever (names may be plain or secret differently), and run lint and WowfProbe.
4. Content data such as zones, quests, items and races differs. Forever is the original world plus new zones; key on IDs.

## 3. From Classic Era (treat as a rewrite that keeps the SavedVariables schema)
1. `## Interface: 16001`; an existing `_Vanilla.toc` stays for Classic.
2. Replace globals using the table in api-migration.md (`GetSpellInfo` → `C_Spell.GetSpellInfo`, etc.), with nil checks and load requests.
3. Delete combat-log listeners. Use unit events.
4. Sounds: `PlaySoundFile("Sound\\...")` → FileDataID or SOUNDKIT [F-101].
5. Options: `InterfaceOptions_AddCategory` → the Settings API.
6. Minimap icon libraries → the addon compartment (keep LibDBIcon only if players want a minimap button).
7. Faction checks: `UnitIsEnemy` → compare `UnitFactionGroup`.
8. Names: two-part names [F-080]; fix any name-realm keys and migrate old keys in SavedVariables.
9. `UnitAura` → `C_UnitAuras` (display only).

## 4. Library traps
- **AceDB-3.0 below MINOR 39** crashes on an unknown `GetCurrentRegion()` [F-064]. Update Ace3 (MINOR ≥ 39).
- **Libs/ empty in git** (filled by `.pkgmeta` at package time): fetch the libraries before testing.
- **Chomp/ChatThrottleLib:** no ASCII control characters in payloads [F-091].
- **LibStub-based libraries** built for Classic may call removed globals. Lint the Libs folder too (`cli.py lint Addon` skips `Libs/` by default; lint the lib folder directly when in doubt).
- **WeakAuras** stopped before Midnight; "WeakAuras Forever" is a different fork with combat-log triggers that never fire.

## 5. Finish
Run `cli.py lint`, deploy, then test in game: a full logout and login for SVs, a combat test with `addonCombatRestrictionsForced`, and `/wowfprobe`. Write the tested build number into the CHANGELOG.
