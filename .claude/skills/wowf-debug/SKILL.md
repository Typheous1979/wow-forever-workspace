---
name: wowf-debug
description: Diagnose World of Warcraft Forever addon problems from evidence. Pasted Lua errors, addon missing or out of date in the AddOns list, nothing happens, Interface action failed because of an AddOn, ADDON_ACTION_BLOCKED, secret value errors, taint, settings not saving, client crashes. Reads SavedVariables, AddOns.txt, taint.log, client logs and crash reports from disk without executing Lua, and runs the WowfProbe dev addon to measure what the live client provides. Use for any in-game bug, error text, or question about testing on the real client.
argument-hint: "[Addon or error text]"
allowed-tools: Bash(python "${CLAUDE_SKILL_DIR}/scripts/savedvars.py" *) Bash(python "${CLAUDE_SKILL_DIR}/scripts/client_logs.py" *) Bash(python "${CLAUDE_SKILL_DIR}/scripts/probe_report.py" *)
---

# wowf-debug: evidence first

## Tools (read-only, never execute Lua, never write WTF)
```
python "${CLAUDE_SKILL_DIR}/scripts/savedvars.py" status <Addon>        # AddOns.txt enabled per character, SV files, deploy link
python "${CLAUDE_SKILL_DIR}/scripts/savedvars.py" <Addon>               # pretty-print saved data (--path a.b, --json, --depth N)
python "${CLAUDE_SKILL_DIR}/scripts/savedvars.py" <Addon> --diff        # previous save (.bak) -> current save
python "${CLAUDE_SKILL_DIR}/scripts/client_logs.py" crash               # last crash reports (Errors\*.txt)
python "${CLAUDE_SKILL_DIR}/scripts/client_logs.py" taint --grep <Addon># Logs\taint.log
python "${CLAUDE_SKILL_DIR}/scripts/client_logs.py" show Sound          # any Logs\<Name>.log (Sound, General, Client...)
python "${CLAUDE_SKILL_DIR}/scripts/probe_report.py"                    # ingest the WowfProbe dump
```
Files on disk reflect the last `/reload` or logout. The scripts warn when the game is running.

## Triage ladder (stop at the first hit)
1. **Not in the AddOns list, or "out of date":**
   - `savedvars.py status <Addon>`: is it deployed (junction OK, not dangling) and enabled in AddOns.txt?
   - Is the folder name the same as the TOC name?
   - Is `## Interface` 16001? The TOC must not have a BOM (lint TOC00x).
   - A brand-new folder needs a client restart [F-024].
   - In game: `/dump C_AddOns.GetAddOnInfo("Name")`. The 5th return is the reason: `INTERFACE_VERSION`, `WRONG_GAME_TYPE` (an `AllowLoadGameType` issue), `DEP_*`, `DEMAND_LOADED`, `DISABLED`.
2. **A Lua error.** Make sure errors are visible: `/console scriptErrors 1` (or BugSack). Then map the text with the catalog below. Lint the file.
3. **Secret or taint:** "secret … value", "forbidden table", "execution tainted by". See secret-values.md. Taint log: `/console taintLog 1`, reproduce, `/reload`, then `client_logs.py taint`.
4. **Nothing happens, no error:**
   - Silent protected call [F-050]: watch for "Interface action failed because of an AddOn" (the counter resets only on a client restart).
   - Event misspelled (lint API007).
   - Handler not registered, or the `addonName` comparison wrong in ADDON_LOADED.
   - Sound channel muted (check `Sound.log` or the CVars).
5. **Settings lost:** `savedvars.py <Addon> --diff`.
   - Was the save written (mtime)? Was SV touched at file scope (PAT001)? Did a migration wipe it? Was a secret stored (saved as nil)?
   - Was the client killed (no save on crash or Alt-F4)? Beta builds have reset UI settings [F-060].
6. **Client crash:** `client_logs.py crash`. If `Addons.Current` names an addon, or the crash followed an addon call, suspect a documented-but-crashing API [F-065]. Remove the call, and record the crash in forever-facts.md and `index.CRASHES`.
7. **Beta defect vs our bug:** compare with forever-facts.md section 7 and retest on the newest build. Label it in notes ("beta defect, build N").

## Error catalog
| Error text | Cause | Fix |
|---|---|---|
| `attempt to perform arithmetic on a secret number value (execution tainted by 'X')` | math on `UnitHealth`/`UnitPower`/… | widget display; `issecretvalue` guard |
| `attempt to compare … secret` / `attempt to index a forbidden table` | comparison or indexing of a secret or secret table | guard; don't read restricted data |
| `attempt to call global 'GetSpellInfo' (a nil value)` (any removed global) | Classic-era API | api-migration.md (lint API002) |
| `RestrictedExecution.lua:79: attempt to call a nil value` | secure-snippet environment not loaded (69913 beta defect) | retest on the current build [F-061] |
| `Invalid AddOn name` from `C_AddOns.GetAddOnMetadata` | the addon doesn't exist | pcall for optional dependencies |
| `Error: Invalid import: No module with that name exists` | `import` before the module file loaded, or a missing dependency | load order or `## Dep`; prefer `ns` |
| `AceDB-3.0.lua:…: attempt to concatenate local 'regionKey' (a nil value)` | AceDB below MINOR 39 vs an unknown `GetCurrentRegion()` | update Ace3 [F-064] |
| `ADDON_ACTION_BLOCKED` / `ADDON_ACTION_FORBIDDEN` | protected call from tainted code or in combat | queue for `PLAYER_REGEN_ENABLED`; don't call protected functions |
| `Interface action failed because of an AddOn` (no Lua error) | silent protected call [F-050] | remove the call |
| `'end' expected near <eof>` / `unexpected symbol` | syntax | lint (LUA000/LCE) |
| `invalid escape sequence '\I'` | single backslash in a path string | double the backslashes: `"Interface\\AddOns\\..."` |

## Safe in-game probes
Give Justin these to paste. They only *look*, never call unknown functions [F-065].
```
/dump select(4, GetBuildInfo()), select(2, GetBuildInfo())
/dump WOW_PROJECT_ID, WOW_PROJECT_CAMELOT
/run print(type(C_X), C_X and type(C_X.Fn))
/run local h=UnitHealth("player"); print(issecretvalue and issecretvalue(h))
/dump C_AddOns.GetAddOnInfo("MyAddon")
/dump C_GameRules.GetForeverExperiencePreset()
/run print(GetCVar("Sound_EnableMusic"), GetCVar("Sound_MusicVolume"))
```

**In-game tools:**
- `/fstack` (frame under the mouse), `/etrace` (event trace; shows secret states), `/tinspect <table>`, `/dump expr`, `/reload`.
- Simulate restrictions out of combat with `/console addonCombatRestrictionsForced 1` (also Encounter, ChallengeMode, PvPMatch, Map, Chat; not persisted).

## WowfProbe (dev-only addon in `assets/WowfProbe/`)
It records what this client really provides. It uses `type()`/`pairs()` only and calls nothing outside a whitelist.
1. Deploy it: `wowf-deploy` with `WowfProbe` (in the beta and/or forever client).
2. In game it runs automatically 5 s after login. For an explicit run: `/wowfprobe` (quick) or `/wowfprobe full` (adds every `_G` name and Enum), then accept **Reload UI**.
3. `probe_report.py` prints:
   - the build, interface, project IDs, `[Family]`/`[Game]`, preset and region;
   - whether health and name are secret;
   - the presence of `PlayMusic`/`PlaySoundFile`/`import`/…;
   - the sound CVars and query answers;
   - the documented-vs-runtime namespace diff.

   It also writes `wowf-api/data/runtime-surface.jsonl`, which `wowf-api` and the lint then use.
4. Run it on every new build, and in `_forever_` after Oct 19. Lint-queued unknown names go into `assets/WowfProbe/Queries.lua` automatically.

Never ship WowfProbe; it's marked `## X-Wowf-DevOnly: 1`.
