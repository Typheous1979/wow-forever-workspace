# WoW Forever facts ledger

Facts as of **2026-10-14**. Status tags:
- **[Probe]**: measured in the client (WowfProbe or a community probe);
- **[Source]**: Blizzard UI source, `forever` branch of Gethe/wow-ui-source;
- **[Wiki]**: warcraft.wiki.gg;
- **[Official]**: Blizzard statement;
- **[Community]**: community report;
- **[Unverified]**: not confirmed anywhere yet.

Cite IDs from other files. When a fact changes, edit it **here**: keep the old value with its build, and add the new value.

## Contents
1. Client, builds and products
2. Detection constants
3. TOC and loading
4. API surface changes by build
5. Secret values and restrictions
6. Protected, forbidden and silent calls
7. Beta defects (history)
8. Built-in systems (don't duplicate) and absent systems
9. Names, realms and data shapes
10. Comms and chat
11. Audio
12. World data (zones, races)
13. Retest checklist for every new build

## 1. Client, builds and products
- **[F-001]** Forever = game type **Camelot** in the Mainline family. Blizzard: "Forever and modern WoW (Midnight) are two game types within the Mainline code family: Camelot (to be renamed before launch) and Standard." It shares "the vast majority of APIs available in 12.1.5"; Midnight's addon disarmament, secrets included, is active; the 12.1.0 AuraContainer/AuraButton changes are included. [Official, WoW UI Discord via Wowhead, 2026-09-16]
- **[F-002]** The addon API is "the modern API approach". [Official, dev Q&A 2026-09-17, 01:20:52]
- **[F-003]** Dates:
  - beta Sep 17 – Oct 21/22, 2026;
  - **stress test Oct 19** ("WoW: Forever - Stress Test");
  - **launch Nov 4, 2026, 3:00 p.m. PST**, level cap 60;
  - raids Dec 9; Hardcore in winter.

  [Official]
- **[F-004]** Builds:

  | Build | Date | Note |
  |---|---|---|
  | 69876 | Sep 17 | Beta open |
  | 69913 | Sep 18 | Guide's reference build |
  | 69977 | Sep 22 | |
  | 70009 | Sep 23–24 | |
  | 70058 | | |
  | 70124 | | |
  | 70170 | Oct 1 | |
  | 70205 | Oct 3 | |
  | 70235 | | |
  | 70245 | | |
  | 70291 | Oct 8 | |
  | 70334 | | |
  | 70338 | Oct 9–10 | |
  | 70374 | Oct 13 | |

  [Source: forever branch commits]
- **[F-005]** Version server, Oct 14:
  - `wow_classic_beta` = **1.60.1.70374** (the beta);
  - `wowf` = **1.60.1.70245** (the stress-test/launch product);
  - retail `wow` = 12.1.5.70391.

  Endpoint: `http://us.patch.battle.net:1119/<product>/versions`. [Official data]
- **[F-006]** Client folders:
  - beta: `World of Warcraft\_classic_beta_\` with `WowB.exe`;
  - `wowf` (stress test/launch): **`_forever_`** with `Wow.exe`.

  Interface, WTF and Cache are **per folder**, so addons and SavedVariables don't carry over. [Official CDN product config]
- **[F-007]** Justin's beta client was on build 70338 (Oct 12). Its install path lives in the gitignored `wowf.local.json`. Per-character data lives under `WTF\Account\<acct>\<region-id>\<Char-Realm>\`. [Probe, local disk]

## 2. Detection constants
- **[F-010]** `WOW_PROJECT_CAMELOT = 18` and `WOW_PROJECT_ID = WOW_PROJECT_CAMELOT` since **70170** (`Blizzard_ProjectConstants/Camelot/ProjectConstants.lua`). Other values: `WOW_PROJECT_MAINLINE = 1`, `WOW_PROJECT_CLASSIC = 2`. On 69913–70124 the ID was 1, the same as Mainline. [Source; Wiki Patch 1.60.1/API changes]
- **[F-011]** `WOW_PROJECT_BURNING_CRUSADE_CLASSIC`, `WRATH`, `CATACLYSM` and `MISTS` are **nil** on Forever. [Source]
- **[F-012]** `LE_EXPANSION_LEVEL_CURRENT` lists Forever under `LE_EXPANSION_CLASSIC` (0). The old wiki recipe `WOW_PROJECT_MAINLINE + LE_EXPANSION_CLASSIC` is **false** on 70170+. [Wiki; Source]
- **[F-013]** Recommended detection:
  ```lua
  local isForever = WOW_PROJECT_CAMELOT ~= nil and WOW_PROJECT_ID == WOW_PROJECT_CAMELOT
  -- fallback used by Questie/RXP: interface range
  local iface = select(4, GetBuildInfo())
  local isForeverByInterface = iface >= 16000 and iface < 20000
  ```
  You can also read the TOC: `## X-Game: [Game]` → `C_AddOns.GetAddOnMetadata(addonName, "X-Game") == "Camelot"`. [Source/Wiki]
- **[F-014]** `C_GameRules`: 29 functions.
  - `GetForeverExperiencePreset()` is **nilable**; `Enum.ForeverExperiencePreset` is Classic=0, Modern=1.
  - Also `IsHardcoreActive`, `IsSelfFoundAllowed`, `IsGameRuleActive(Enum.GameRule.X)`, `GetActiveGameMode`.
  - Events: `GAME_RULES_CHANGED`, `ACTIVE_GAME_MODE_UPDATED`.
  - `Enum.GameRule` and `Enum.GameMode` are runtime-only (not in the docs).
  - `C_GameRules.Select{Classic,Modern}ExperiencePreset` was removed in 70009.

  [Source; Community fact sheet]

## 3. TOC and loading
- **[F-020]** Interface **16001** for Forever Beta (70374) and Forever Test/PTR (70245). The live "Forever" row is still blank. Retail Standard is 120100; Standard Test is 120105. [Wiki TOC_format]
- **[F-021]** Game-type tokens:
  - `camelot`, alias `forever` (since **70291**);
  - family `mainline` (includes camelot, standard, plunderstorm, wowhack);
  - `standard` = retail only;
  - `classic` = vanilla/tbc/wrath/cata/mists.

  `[Family]` expands to `Mainline` and `[Game]` to `Camelot`. [Source; Wiki]
- **[F-022]** Suffix precedence on Forever: `_Camelot`/`_Forever` > `_Mainline` > bare `Name.toc`. Shipped addons use `_Camelot.toc` (Questie, MapUtils, MoveAny), `-Camelot.toc` (Guidelime) and multi-value Interface lines (RXP, TomTom). `_Forever.toc` is unverified in the wild. [Wiki; observed]
- **[F-023]** Inline `[AllowLoadGameType camelot]`: if **no** listed type is recognized, the line STILL LOADS. Pair it with `[ExcludeLoadGameType ...]`. [Wiki]
- **[F-024]** New addon folder: the wiki says `/reload` detects new addons (9.0.1+); the community says Forever needs a full client restart. Treat restart as the safe default and **record what Justin observes**. [Wiki vs Community — conflict]
- **[F-025]** Out-of-date: an addon whose Interface doesn't match is flagged out of date. Whether Forever force-blocks them, as Midnight does below 120000, is undocumented. [Wiki TODO]
- **[F-026]** `## LoadSavedVariablesFirst: 1` (11.1.5+) loads SVs before your files. Questie's Forever TOC uses it. [Wiki; observed]

## 4. API surface changes by build
- **[F-030]** Absent on 69913: `GetSpellInfo`, `GetItemInfo`, `GetSpellBookItemName`, `GetNumTalentTabs`, `GetTalentInfo`, `GetNumSkillLines`, `GetSkillLineInfo`, `UnitAura`, `GetAddOnMetadata`, `UnitPVPRank`, `GetPVPRankInfo`. `IsSpellKnown` survives. [Community probe 69913]
- **[F-031]** 12.1.5 (Forever's base) removed about 40 item globals (`GetItemInfo`, `GetItemCount`, `GetItemIcon`…), the coin-string helpers and `PlayVocalErrorSoundID`. 12.0.0 removed the spell globals, `CombatLog*`, the action-bar globals and `IsEncounterInProgress`. Full table: `api-migration.md` and `tools/wowf/data/removed_apis.json`. [Wiki]
- **[F-032]** Forever-only namespaces: C_SwingTimer, C_AutoLoot, C_LootFrame, C_Flyout, C_LFGListRoles, C_NameUtil, C_GamepadUI, C_GamepadTargeting, C_InputInterfaceStyle, C_BlizzCon2026 (+ constants). Also `C_SkillInfo`, `C_PetInfo.GetPetHappiness/Loyalty/TrainingPoints`, `UnitUsesAmmo`, `UnitDefenseSkill`, `UnitResistance`, `ToggleSit`, `UIReload`, `C_CVar.SetTempCVar`/`RemoveTempCVar`, `C_DateAndTime.IsDayTime`, and the events `DIEL_CYCLE_CHANGED`, `PLAYER_SWING`, `UNIT_HAPPINESS`. [Source; Wiki]
- **[F-033]** Lua `require` was added, then renamed to **`import`** in 70291. It returns the value a *loaded* module file returned and can't load new files. [Wiki API:import]
- **[F-034]** Documented C_ namespaces vs runtime on 69913: 277 documented, 269 present, 27 documented-but-absent, about 19 present-but-undocumented. [Community probe]
- **[F-035]** `PlayMusic`, `StopMusic`, `PlaySoundFile`, `StopSound`, `MuteSoundFile` and `UnmuteSoundFile` are **not in any generated doc**, yet they are used on Forever (Questie `PlaySoundFile(fileID, ch)`; the Soundtrack port played MP3s; Blizzard code calls `StopSound`). **Confirmed present (all six are functions) on 70374.** [Probe 70374]
- **[F-111]** WowfProbe on beta 70374 (Oct 14 2026, enUS, preset 1, out of combat):
  - `WOW_PROJECT_ID` = `WOW_PROJECT_CAMELOT` = 18 (MAINLINE 1, CLASSIC 2). TOC `[Family]/[Game]` expand to `Mainline/Camelot`.
  - `C_Secrets.HasSecretRestrictions()` returns true. `UnitHealth("player")` is secret even out of combat. `UnitHealthMax("player")` and `UnitName("player")` are **not** secret (out of combat, open world; consistent with [F-042]).
  - `StaticPopup_Show` from a slash command: the dialog didn't appear on the first run after a fresh client start, but did on the next run (after `/reload`). Cause unknown, so always print a `/reload` hint as a fallback.
  - Nil: `GetSpellInfo`, `UnitAura`, `GetAddOnMetadata`, `CombatLogGetCurrentEventInfo`, `InterfaceOptions_AddCategory`, `SetDesaturation`, `require`.
  - Present: `import`, `issecretvalue`, `canaccessvalue`, `scrubsecretvalues`, `UIReload`, `loadstring`, `getfenv`/`setfenv`, `newproxy`.
  - `GetItemInfo` is a global function at runtime. The docs don't list it and 12.1.5 removed it ([F-031]). Another installed addon may define it, so keep using `C_Item.GetItemInfo`.
  - 271 C_ namespaces at runtime vs 283 documented. Documented but absent: C_EncounterInfo, C_CombatLogSecure/Internal, C_Vehicle, C_TraitConfig, C_BattlePet, C_DuelInfo, C_ItemText, C_WorldStateInfo, C_GlyphInfo and 22 more. Present but undocumented: C_Heirloom, C_ToyBox, C_Scenario, C_Debug, C_Widget and 14 more. The full list is in `wowf-api` (runtime layer). [Probe 70374]
- **[F-036]** `Menu.ModifyMenu` / `MenuUtil` are FrameXML Lua tables (not in the C docs) and present. Legacy `UnitPopupButtons` is nil. [Community probe]
- **[F-037]** `SetDesaturation` has no Lua definition on Forever (use `texture:SetDesaturated`). Questie reports the `UnitAura` global "can fail internally". [Source; Community]
- **[F-038]** Absent Blizzard UI on Camelot: EncounterJournal, ChallengesUI, retail GroupFinder (Forever has GroupFinder_VanillaStyle), PVPUI, PerksProgram, Housing*, Delves*, ExpansionLandingPage. Present only on Camelot: SwingTimer, Statistics, LegacySystem/LegacyChallengeTracker, Gamepad*, HardcoreUI, QuestTimer. Check with `wowf-api addon Blizzard_X`. [Source]

## 5. Secret values and restrictions
- **[F-040]** Secret values are active (Midnight rules). `C_Secrets.HasSecretRestrictions()` reports it. [Official; Source]
- **[F-041]** `UnitHealth`: `SecretReturns` (always secret), observed even out of combat for the player and friends. `type()` says "number" and `h + 1` throws. [Source; Probe 69913; Community]
- **[F-042]** `UnitHealthMax` is secret when the unit isn't player-controlled. `UnitPower` is secret for power types not flagged never-secret. [Source]
- **[F-043]** `UnitName`, `UnitFullName`, `UnitGUID`, `UnitClass` (name), `UnitRace`… are secret when **unit identity is restricted**: the unit isn't player-controlled and isn't in your party/raid, and on instanced maps every unit except player, pet, vehicle and group. [Source; Wiki 12.0.5]
- **[F-044]** Not annotated secret: `UnitExists`, `UnitCanAttack`, `UnitIsEnemy`, `UnitIsFriend`, `UnitLevel`, `UnitIsPlayer`, `UnitIsDead`, `UnitAffectingCombat`, `GetZoneText`, `GetSubZoneText`, `C_Map.GetBestMapForUnit`. Community notes claim `UnitExists`/`UnitCanAttack` can be secret booleans; guard anyway when the input is a non-group unit. [Source vs Community]
- **[F-045]** Spell-cast event payloads can be secret for non-player units (Guidelime fix for `UNIT_SPELLCAST_SUCCEEDED`). Questie had secret-value error spam in instances. [Community]
- **[F-046]** **Printing** a secret throws on Forever and can blank your frame (concatenation alone is allowed by the wiki rules). [Community]
- **[F-047]** The restriction system: `Enum.AddOnRestrictionType` (Combat, Encounter, ChallengeMode, PvPMatch, Map, Chat), the event `ADDON_RESTRICTION_STATE_CHANGED`, and the test CVars `addon*RestrictionsForced`. [Wiki/Source]
- **[F-048]** `GetFrameStrata` returns a secret for frames with the new FrameStrata secret aspect (70291). [Wiki]

## 6. Protected, forbidden and silent calls
- **[F-050]** Silent failure (no Lua error, `pcall` useless): `ChatFrame_OpenChat`, `ChatEdit_ActivateChat`, `C_SuperTrack.SetSuperTrackedUserWaypoint`, and secure attributes on Blizzard unit frames. The symptom is "Interface action failed because of an AddOn" plus an AddOns-panel counter that only a **full restart** clears. [Community]
- **[F-051]** Forbidden or protected:
  - setting raid target markers (`SetRaidTarget`);
  - casting on units in combat;
  - writing bindings, placing action slots and creating macros — allowed only out of combat.

  [Community addon authors]
- **[F-052]** Docs flag `IsProtectedFunction` (74 functions, mostly widget methods such as `Frame:SetAttribute`/`ClearAttribute`; these are blocked in combat or on protected frames) and `HasRestrictions` (276). Systems with `Environment="SecureOnly"` (e.g. `C_CombatLogSecure`) can't be called by addons. [Source]
- **[F-053]** `C_ChatInfo.SendChatMessage` has `HasRestrictions` + `RestrictedForMacroChatMessages`. EMOTE needs a hardware event outside instances (70291). Trial accounts can't send addon messages (70291). [Source; Wiki]

## 7. Beta defects (history)
- **[F-060]** SavedVariables were written but not restored (Sep 18–21). **Fixed in 70009** (wiki and forum). Builds have since occasionally reset interface settings. [Wiki; Community]
- **[F-061]** Secure snippets failed on 69913 ("RestrictedExecution.lua:79: attempt to call a nil value"). The wiki says 70009 fixed "RestrictedEnvironment not loading". `type(loadstring_untainted) == "nil"` is **by design**, because EnvironmentCleanup clears it for addons. Retest with a real snippet. [Wiki; Source]
- **[F-062]** `UnitName("player")` returned "Unknown", nil before `PLAYER_LOGIN` until 70170. [Wiki]
- **[F-063]** `NAME_PLATE_UNIT_ADDED` fires before the unit is populated, and plate frames lack `namePlateUnitToken`. Recheck after `C_Timer.After(0)` or sweep `nameplate1..40`. [Community, unverified]
- **[F-064]** `GetCurrentRegion()` returned an unknown region ID on the beta, crashing AceDB-3.0 below MINOR 39. Ship Ace3 with MINOR ≥ 39 (`GetCurrentRegionName()` fallback). [Community; Source]
- **[F-065]** `C_Housing.GetMaxHouseLevel` (documented, present) **access-violates the client**, so pcall can't catch it (69913). [Community probe]

## 8. Built-in systems (don't duplicate) and absent systems
- **[F-070]** Built in:
  - **Damage meter** and **cooldown manager** (all classes, racials and trinkets as of Oct 8);
  - **swing timer** (Edit Mode; `C_SwingTimer`);
  - **click-cast bindings** and **mouseover cast** (Options > Keybindings);
  - ping wheel;
  - Edit Mode (layouts saved per UI type since 70291).

  [Official; Source; Community]
- **[F-071]** Classic Mode (chosen at first login) turns off quest tracking and transmog. `Enum.ForeverExperiencePreset` Classic/Modern. [Official]
- **[F-072]** Absent: Encounter Journal, M+ Challenges, Housing, Delves, Trading Post, retail PvP UI ([F-038]). [Source]

## 9. Names, realms and data shapes
- **[F-080]** Two-part names ("First Surname"), unique per region. On **70009+**, `UnitFullName("player")` returns `"First", "Surname"` (the surname sits in the realm slot). `UnitName` returns the first name. `GetNormalizedRealmName()` is still the realm. Whisper and ignore need the full name. `C_PlayerInfo.ShouldDisplaySurname()`. [Community probe 70009]
- **[F-081]** "Super districts" and rulesets replace realms: Normal, PvP, Roleplaying, Hardcore (later). The auction house is per ruleset. `/who` can be disabled (`IngameWhoListDisabled` game rule). [Official; Source]
- **[F-082]** Races include **Windshaper Skyborne** (Horde) and **High Order Skyborne** (Alliance); race ID 96 was seen. [Community]

## 10. Comms and chat
- **[F-090]** `C_ChatInfo.SendAddonMessage(prefix ≤16, message ≤255, chatType, target)` → `Enum.SendAddonMessageResult` (11 = AddOnMessageLockdown). Throttle: 10 per prefix, regaining 1 per second. Register the prefix every session. There's a lockdown during encounters, M+ and PvP. [Wiki; Source]
- **[F-091]** Transport libraries such as Chomp reject ASCII control characters (0x01–0x1F, 0x7F), and 240-byte chunks were observed. [Community probe]

## 11. Audio
- **[F-100]** `PlaySound(soundKitID [, channel, forceNoDuplicates, runFinishCallback])` is an alias of `C_Sound.PlaySound` (6 args, `volumeOverride` from 12.1.0). Pass a SOUNDKIT ID, never a string. [Source]
- **[F-101]** Internal game paths (e.g. `Sound\Interface\x.ogg`) stopped working in **8.2.0**; they fail silently. Use FileDataIDs, SOUNDKIT, or addon-folder paths. [Wiki; Community]
- **[F-102]** Custom MP3 paths in an addon folder played on Forever (Soundtrack port, ~69913). [Community]
- **[F-103]** `Sound_ZoneMusicNoDelay` is the "Loop Music" checkbox (ENABLE_MUSIC_LOOPING). `Sound_EnableSoundWhenGameIsInBG` defaults to 0. Sound CVars aren't secure. Camelot has no pet-battle music. [Source; Probe Sound.log]
- **[F-104]** There are no music, jukebox or playlist events, and no API for track length, position, pause or seek. [Wiki; Source]
- **[F-105]** The Forever OST was released (Oct 13). Forever-only music sets exist (troll/pirate/naga for The Drowned City; Dalaran sewers/spire). [Official; Community datamine]

## 12. World data
- **[F-110]** New zones:
  - **Zephras Isle** (1–12, Skyborne start; Soundtrack resolved it as "Unknown/Zephras Isle", with no continent parent);
  - **Riverglades** (mid-30s–40s, east Eastern Kingdoms);
  - **Shen'dralas** (between Mulgore and Desolace, area 16651);
  - **Mount Hyjal** (endgame leveling; Darkwhisper Gorge).

  Don't assume every zone has a Kalimdor or Eastern Kingdoms parent. [Official; Community]

## 13. Retest checklist (run on every new build)

Use `/wowfprobe full`, then `cli.py probe-report`.
1. Build, interface, `WOW_PROJECT_ID`, `[Game]`/`[Family]`, Forever preset.
2. Health and name secrecy in and out of combat. Turn on `addonCombatRestrictionsForced` to simulate combat.
3. The presence of `PlayMusic`, `PlaySoundFile`, `StopMusic`, `MuteSoundFile`, `import`, `GetSpellInfo` and `UnitAura`.
4. SavedVariables persist across a **full logout** (not just `/reload`).
5. Does a brand-new addon folder load after `/reload`, or only after a restart? ([F-024])
6. Run a real secure snippet ([F-061]).
7. `GetCurrentRegion()` value ([F-064]).
8. The documented-vs-runtime namespace diff ([F-034]).
