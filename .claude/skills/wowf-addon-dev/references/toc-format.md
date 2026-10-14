# TOC format for WoW Forever

## Basics
- `Interface\AddOns\<Name>\<Name>.toc`. The **folder name must equal the TOC name** (case-sensitive match on the name).
- Three line kinds:
  - `## Directive: Value`;
  - `# comment`;
  - a file path (`Core.lua`, `UI\Panel.xml`). Use backslashes.
- Only Lua and XML files are listed. Art and sound files aren't.
- Files load top to bottom, then SavedVariables, then `ADDON_LOADED`.
- Only the first 1024 characters of each line are read.
- Save as UTF-8 **without BOM**. Write with the Write tool, never PowerShell `Out-File`.

## Interface
- A Forever-only addon uses `## Interface: 16001` [F-020].
- A multi-client addon uses a comma-separated list, e.g. `## Interface: 120100, 120105, 16001, 11509`.
- The live Forever interface number may change at launch; the wiki's "Forever" row is still blank. `/wowf-refresh` checks it.

## Which TOC the Forever client loads [F-022]
`_Camelot.toc` / `_Forever.toc` (game type) beat `_Mainline.toc` (family), which beats `<Name>.toc`. Patterns seen in shipped Forever addons:

| Pattern | Example |
|---|---|
| Single TOC, single interface | most Forever-only addons: `## Interface: 16001` |
| Multi-value Interface + inline conditions | RXPGuides, TomTom, Auctionator |
| Per-client TOC siblings | MapUtils/MoveAny/WhisperMessenger/Questie `_Camelot.toc`; Guidelime `-Camelot.toc` |
| Fallback TOC for unsupported clients | Questie `Questie.toc` with `## Interface: 00000` and a "game client not supported" title |

## Game types and variables [F-021]
- Game types: `camelot` (alias `forever`, 70291+), `standard` (retail only), `plunderstorm`, `wowhack`, `vanilla`, `tbc`, `wrath`, `cata`, `mists`.
- Families: `mainline` (includes camelot) and `classic`.
- Path variables expand at load time:
  - `[Family]`: Mainline or Classic;
  - `[Game]`: Camelot on Forever ("may become Forever");
  - `[TextLocale]`: enUS and so on.

```
[Family]\Compat.lua
[Game]\Compat.lua
Locales\[TextLocale].lua
```

## Load conditions
Header form (whole addon):
```
## AllowLoadGameType: camelot, standard
## ExcludeLoadGameType: classic
```
Inline form (per file, put at the end of the line):
```
ForeverOnly.lua [AllowLoadGameType camelot][ExcludeLoadGameType standard, classic]
EnglishOnly.lua [AllowLoadTextLocale enUS]
```
**Trap [F-023]:** if none of the listed types is recognized by the client, the line still loads. Pair Allow with Exclude, and spell tokens correctly; lint rule TOC006 checks this.

Per-directive conditions (12.0.7+): `## Title: My Addon (Forever) [AllowLoadGameType forever]`. List the `forever` line first, because clients that don't know `forever` still load it and later lines overwrite.

## Directives
| Directive | Notes |
|---|---|
| `Title`, `Notes`, `Title-deDE`… | colour codes allowed; put the unlocalized line first |
| `Author`, `Version` | read with `C_AddOns.GetAddOnMetadata` |
| `Category` (+ `Category-xxXX`), `Group` | AddOn list grouping; audio addons use **Media** |
| `IconTexture` / `IconAtlas` | texture path or fileID; IconTexture wins |
| `AddonCompartmentFunc`, `AddonCompartmentFuncOnEnter`, `AddonCompartmentFuncOnLeave` | names of **global** functions; see ui-patterns.md |
| `SavedVariables`, `SavedVariablesPerCharacter` | global table names (comma-separated) |
| `LoadSavedVariablesFirst: 1` | SVs load before your files (11.1.5+) |
| `Dependencies` / `RequiredDeps`, `OptionalDeps` | |
| `LoadOnDemand: 1`, `LoadWith`, `LoadManagers` | |
| `DefaultState: disabled`, `OnlyBetaAndPTR: 1` | |
| `AllowAddOnTableAccess: 1` | lets others read your namespace via `C_AddOns.GetAddOnLocalTable` |
| `X-Anything` | custom metadata, e.g. `## X-Game: [Game]` for detection |
| `[Bootstrap]` (inline) | files to load at startup for LoadOnDemand addons (12.1.0+) |

Blizzard-only directives (not usable by addons): `AllowLoad`, `LoadFirst`, `UseSecureEnvironment`, `SavedVariablesMachine`.

## Templates

**Forever-only:**
```
## Interface: 16001
## Title: My Addon
## Notes: One line about what it does.
## Author: Justin
## Version: 0.1.0
## Category: Media
## IconTexture: Interface\Icons\INV_Misc_Note_01
## SavedVariables: MyAddonDB
## SavedVariablesPerCharacter: MyAddonCharDB
## AddonCompartmentFunc: MyAddon_OnAddonCompartmentClick
## AddonCompartmentFuncOnEnter: MyAddon_OnAddonCompartmentEnter
## AddonCompartmentFuncOnLeave: MyAddon_OnAddonCompartmentLeave
## X-Game: [Game]

Locales\enUS.lua
Core.lua
Options.lua
```

**One package for Midnight and Forever:**
```
## Interface: 120100, 120105, 16001
## Title: My Addon
## SavedVariables: MyAddonDB

Core.lua
Forever.lua [AllowLoadGameType camelot, forever][ExcludeLoadGameType standard, classic]
Retail.lua [AllowLoadGameType standard][ExcludeLoadGameType camelot, classic]
```
