---
name: wowf-review
description: Lint and hostile-review World of Warcraft Forever addon code before it ships. Runs the wowf Forever lint (TOC wiring and interface 16001, Lua 5.2+ syntax, removed and banned APIs, combat log, invented C_ functions and events, SavedVariables at file scope, slash command and addon compartment wiring, secret-value math, silent protected calls) plus luacheck, then a manual checklist. Use after writing or changing any addon Lua or TOC, before deploying, when an addon misbehaves, or when asked to review, lint, check or audit a Forever addon.
argument-hint: "[AddonFolder]"
allowed-tools: Bash(python "${CLAUDE_SKILL_DIR}/scripts/lint.py" *)
---

# wowf-review: lint, then think

## 1. Run the lint
```
python "${CLAUDE_SKILL_DIR}/scripts/lint.py" <AddonFolderOrPath>            # human output
python "${CLAUDE_SKILL_DIR}/scripts/lint.py" <Addon> --json                  # machine output
python "${CLAUDE_SKILL_DIR}/scripts/lint.py" <Addon> --no-luacheck --min W   # fast, hide notes
```
- Output format: `path:line:col: SEV [ID] message -> fix`. Exit 1 means there are errors.
- `luacheck.exe` must be installed. If the output says `LC000 ... not installed`, run `python tools/wowf/setup_luacheck.py` once.
- Unknown C_ names and events get queued for WowfProbe (`--no-queries` turns that off).

**Fix every E.** For each W, fix it or explain why it's fine. Suppress only with a reason: `-- wowf-ignore: ID reason` on the same or the previous line.

## 2. Rule reference
| ID | Sev | Meaning |
|---|---|---|
| TOC001 | E | TOC name ≠ folder name |
| TOC002 | E | no TOC Forever will load, or Interface lacks 16001 |
| TOC003 | E/W | listed file missing (W = case mismatch) |
| TOC004 | W | .lua/.xml not listed (also catches OneDrive conflict copies) |
| TOC005 | E | compartment function named in the TOC isn't defined as a global |
| TOC006 | W | unknown game-type token (the line still loads!) |
| TOC007 | E/W | UTF-8 BOM in a TOC (E) or Lua file (W) |
| LUA000 | E | syntax error (tokenizer) |
| LUA001–004 | E | `goto`/labels, `//`, bitwise operators, `_ENV` (Lua 5.2+) |
| LUA005 | W | `\x \z \u{}` escapes (mangled in 5.1) |
| API001 | E | `require`/`dofile`/`loadfile`/`io`/`package`, `os.*` other than time/date/clock/difftime |
| API002 | E/W | removed global (W if only a deprecated shim remains) |
| API003 | E | combat log (`COMBAT_LOG_EVENT_UNFILTERED`, `CombatLog*`) |
| API004 | E/I | SecureOnly system (E); HasRestrictions function (I) |
| API005 | E | old InterfaceOptions API |
| API006 | E | sound/music call with an internal game path, or `PlaySound("string")` |
| API007 | E/W | unknown C_ namespace or function, unknown event, known crasher; W = documented but absent at runtime |
| PAT001 | E | SavedVariable touched at file scope |
| PAT002 | E | using the result of a function that returns nothing (`C_Timer.After`) |
| PAT003 | W | `WOW_PROJECT_ID` branch with no `WOW_PROJECT_CAMELOT` anywhere |
| PAT004 | W | file doesn't start with `local addonName, ns = ...` |
| PAT005 | E | `SLASH_X1` / `SlashCmdList["X"]` mismatch, numbering, missing `/` |
| SEC001 | W/I | secret (W) or possibly-secret (I) value used in math, comparison, concat or tostring |
| SEC002 | E | known silent-fail protected call |
| SEC003 | W | calling a protected function |
| LCxxxx | E/W | luacheck: E0xx syntax; W111 leaked global; W113 undefined (often misspelled API); W121 overwrote a Blizzard global; W143 invented field on a known table; W211 unused local |

## 3. Hostile manual review (the lint can't see these)
Go through every file and write findings under these headings. Write "clean" if a heading has none.
1. **Secret flow:** does any value from `UnitHealth`/`UnitPower`/`UnitName`/auras/cooldowns reach math, comparisons, `print`, table keys or SavedVariables through helpers or other files?
2. **Combat:** any Show/Hide/SetPoint/SetAttribute on protected or secure frames without `InCombatLockdown()` queuing? Any protected call in a code path that runs in combat?
3. **Built-ins:** does it duplicate the damage meter, cooldown manager, swing timer, click casting or mouseover cast? Does it depend on systems absent on Forever (Encounter Journal…)?
4. **Data keys:** are names or realms used as keys (two-part names [F-080])? Are new zones without a continent parent handled?
5. **Lifecycle:** are SVs initialized only in ADDON_LOADED, migrated forward and never wiped? Is there work in OnUpdate that should be a timer or event? Are any timers left uncancelled?
6. **Automation creep:** does anything act for the player (casting, chat, markers, targeting) instead of informing?
7. **Unverified APIs:** for every API marked undocumented or curated in `wowf-api`, is there a runtime probe result? If not, say so.
8. **Fragments:** are the full TOC and every Lua file present and listed?

Quote the line, say why it fails on Forever, and give the replacement.

## 4. Report
Give lint counts (E/W/I), the fixes made, the remaining warnings with justifications, and the manual-review findings. Mention the index build and runtime probe build printed on the lint's last line.
