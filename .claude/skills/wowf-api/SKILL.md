---
name: wowf-api
description: Verify a World of Warcraft Forever API, event, enum or sound kit against Blizzard's forever-branch API docs, FrameXML source and the WowfProbe runtime dump. Answers whether it exists, its exact signature, defaults, nilable returns, whether it is secret, protected, restricted or SecureOnly, which Blizzard UI addons load on Forever, and what changed between builds. Use before writing any API call not already shown in the wowf references, whenever unsure a function exists, when asked does X exist or what does Y return, and to avoid inventing C_ functions.
argument-hint: "[show|find|events|soundkit|addon|builds|diff|update] [name-or-regex]"
allowed-tools: Bash(python "${CLAUDE_SKILL_DIR}/scripts/api.py" *)
---

# wowf-api: look it up, never guess

The index merges three layers, and every answer says which layers know a name:
- **doc**: Blizzard's generated API documentation for the Forever client (`Blizzard_APIDocumentationGenerated`, build in the meta line; 70374 at creation).
- **fx**: globals defined in Blizzard's Forever FrameXML Lua/XML (`Settings`, `MenuUtil`, `StaticPopup_Show`, `SOUNDKIT`, `UIParent`…), plus a curated list of **undocumented C functions** with evidence (`PlayMusic`, `PlaySoundFile`, `StopSound`…).
- **rt**: names actually present in the running client, from the WowfProbe dump (`wowf-debug`). Documented ≠ present.

## Commands
Run from anywhere in the workspace:
```
python "${CLAUDE_SKILL_DIR}/scripts/api.py" show C_Sound.PlaySound      # signature, flags, secrecy, source file
python "${CLAUDE_SKILL_DIR}/scripts/api.py" show UnitHealth
python "${CLAUDE_SKILL_DIR}/scripts/api.py" find "^C_Map\.Get"            # regex over names
python "${CLAUDE_SKILL_DIR}/scripts/api.py" find Music --kind fn --kind fx
python "${CLAUDE_SKILL_DIR}/scripts/api.py" events "ZONE|WEATHER"        # event names + payloads
python "${CLAUDE_SKILL_DIR}/scripts/api.py" show Enum.ForeverExperiencePreset
python "${CLAUDE_SKILL_DIR}/scripts/api.py" soundkit "READY|RAID"
python "${CLAUDE_SKILL_DIR}/scripts/api.py" addon Blizzard_EncounterJournal   # does that Blizzard UI load on Forever?
python "${CLAUDE_SKILL_DIR}/scripts/api.py" builds                     # index vs cache vs client vs version server
python "${CLAUDE_SKILL_DIR}/scripts/api.py" update                     # fetch latest forever build + rebuild index (slow, network)
python "${CLAUDE_SKILL_DIR}/scripts/api.py" diff [GITREV]              # what changed in the committed index
```
`--kind` values: fn, method, event, enum, const, struct, callback, ns, pred, fx, rt.

## Reading the output
`C_X.Fn(arg:type=default, opt:type?) -> ret:type`, then tags:
- `[secret:always]` or `[secret:conditional]`: never do math, compare or print with the result; draw it with a widget (see `wowf-addon-dev` secret-values.md). The `flags:` line names the predicate, e.g. `SecretWhenUnitIdentityRestricted`.
- `[protected]`: blocked in combat or on protected frames.
- `[restricted]` (`HasRestrictions`): may silently do nothing in restricted states.
- `[secure_only]`: addons can't call it.
- `[forever_only]`: doesn't exist on retail; guard it in multi-client addons.
- `CRASHES CLIENT`: a known access violation; never call it.
- `FrameXML ... NOT loaded on Forever`: the Lua exists in the source but isn't loaded for the Camelot game type.
- `undocumented C global — evidence: ...`: exists per curated evidence; confirm with the runtime layer.

## When the answer is "not in the index"
1. Check spelling: `find` with a partial regex. The command prints "did you mean".
2. If nothing matches, **say it's unknown on Forever**. Don't invent a substitute. Give the user a safe probe that only *looks*, never calls:
   `/run print(type(C_X), C_X and type(C_X.Fn))`
3. Lint queues unknown names into WowfProbe's `Queries.lua`; the next `/wowfprobe` answers them.
4. For semantics (what a parameter means), fetch the Warcraft Wiki page via its API (see `wowf-addon-dev/references/sources.md`). The wiki documents retail, so treat its claims as [Wiki] and confirm the Forever presence here.

## Keeping it current
The index snapshot is committed under `data/` so lookups work offline. When `builds` shows a newer server build than the index, run `update`, then `diff`, then summarize the changes for Justin (or run `/wowf-refresh`).
