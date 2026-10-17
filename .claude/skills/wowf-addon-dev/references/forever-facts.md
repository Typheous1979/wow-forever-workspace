# WoW Forever facts ledger

Facts as of **2026-10-16** (§13 added and its AH probes run on 70425; earlier sections last checked 2026-10-14). Status tags:
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
13. Economy: auction house, professions, vendors
14. Retest checklist for every new build

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
  | 70425 | Oct 16 | beta server and Justin's client; API index rebuilt |
  | 70450 | Oct 16 (late) | beta server; API index rebuilt (no AH, profession or merchant API changes) |

  [Source: forever branch commits]
- **[F-005]** Version server, Oct 14:
  - `wow_classic_beta` = **1.60.1.70374** (the beta);
  - `wowf` = **1.60.1.70245** (the stress-test/launch product);
  - retail `wow` = 12.1.5.70391.

  Oct 16: `wow_classic_beta` = **1.60.1.70425**, then **1.60.1.70450** the same evening; `wowf` still 1.60.1.70245.

  Endpoint: `http://us.patch.battle.net:1119/<product>/versions`. [Official data]
- **[F-006]** Client folders:
  - beta: `World of Warcraft\_classic_beta_\` with `WowB.exe`;
  - `wowf` (stress test/launch): **`_forever_`** with `Wow.exe`.

  Interface, WTF and Cache are **per folder**, so addons and SavedVariables don't carry over. [Official CDN product config]
- **[F-007]** Justin's beta client was on build 70338 (Oct 12), **70425** on Oct 16. Its install path lives in the gitignored `wowf.local.json`. Per-character data lives under `WTF\Account\<acct>\<region-id>\<Char-Realm>\`; on 70425 the "Char-Realm" folder is `<First>-<Surname>` (the surname takes the realm slot, [F-080]) under region-id `70`. Folders from older builds (`<Realm Name>\<First>`) stay beside it. [Probe, local disk 70425]

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
  - An **existing** addon's changed TOC (five new Lua files, a new `## Version`) was re-read on `/reload`, no restart (BuffettForever 0.2.0). [Probe 70425] A brand-new folder is still unrecorded.
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
  - **[F-112]** `PlaySoundFile(id, "Master")` returns `willPlay = true` plus a handle even for IDs that are not sound files (`1`, `999999999`), so `willPlay` can't detect missing music. All 769 MusicForever catalog IDs returned true as well. **`C_Sound.IsPlaying(handle)` does tell them apart**: checked about 0.25 s after starting, both controls are false. 747 of the 769 catalog files played; the 22 silent ones are Classic Era 1.15.x files (Karazhan Crypts, Scarlet Enclave) that are encrypted in Forever's data. Test availability with `IsPlaying`, never with `willPlay`. [Probe 70374]
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
- **[F-083]** Realm values on the beta: `GetRealmName()` = `"Classic Beta PvP 2"`, `GetNormalizedRealmName()` =
  `"ClassicBetaPvP2"`, `UnitFactionGroup("player")` = `"Horde"`, `C_GameRules.IsHardcoreActive()` = false;
  `UnitFullName("player")` returned the first name and the surname, as [F-080] says. Launch super-district names
  and whether the AH is shared across factions or realms of one ruleset: **unmeasured**. [Probe 70425]

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

## 13. Economy: auction house, professions, vendors
Details and code: auction-house.md, professions-and-vendors.md; pricing math: the `wowf-economics` skill.
- **[F-120]** Only the **modern** auction house exists. All 85 `C_AuctionHouse` functions are documented and
  present at runtime; `Blizzard_AuctionHouseUI` is LoadOnDemand (`AllowLoadGameType: mainline, cata, mists`)
  with a Forever category file `Camelot\Blizzard_AuctionData.lua` (vanilla weapon and armor types, soul bags,
  quivers, ammo pouches, Trade Goods, Recipes, WoW Token). Every Classic AH global (`QueryAuctionItems`,
  `GetAuctionItemInfo`, `CanSendAuctionQuery`, …) and the global `CloseAuctionHouse` are absent; `AuctionFrame`
  is nil. `Enum.PlayerInteractionType.Auctioneer = 21`. Search queries are capped at 100 per minute (docs).
  Scanning has no restriction flags; post, bid, buy and cancel are `HasRestrictions`. [Source; Probe 70374]
- **[F-121]** AH prices are copper (`BigUInteger`). `GetReplicateItemInfo(index)` has 18 returns; `buyoutPrice`
  is for the whole stack and `hasAllInfo` is nilable. Commodity status by itemID:
  `GetItemKeyInfo(MakeItemKey(id)).isCommodity`; `GetItemCommodityStatus` takes an ItemLocation. [Source 70374]
  Measured by BuffettForever's scanner [Probe 70425]:
  - **The replicate index is 0-based:** rows are `0 .. n-1` with `n = GetNumReplicateItems()`. Index `n` doesn't
    error or return nil: it returns `itemID 0, count -1, buyout 0`. Treat `itemID == 0` as "no row".
  - `REPLICATE_ITEM_LIST_UPDATE` came **4.7 s** after `ReplicateItems()` for 61,933 rows (4.2 s for 62,341). It then
    fired **3,117 more times** (3,113 the next scan) while the rows were read: about once per distinct item, as item
    data for uncached rows arrived. Act on the first one only.
  - 5,390 of the 61,933 rows (8.7%) had `hasAllInfo` false when read, but `itemID`, `count` and `buyoutPrice` were
    always valid. Pricing by itemID doesn't need to wait for the item data.
  - **Cooldown:** a second `ReplicateItems()` 121 s after a successful one got **no event at all** within 60 s. One
    2,300 s (38 min) after the last data got data in 4.2 s. So the cooldown is **between 2 and 38 min** (retail:
    15 min). A request inside the cooldown is ignored, not queued, so use a timeout.
  - **Targeted searches** at one query in flight:
    - Commodity results are **grouped by unit price**: Light Leather returned 41 result rows while the full scan
      showed 295 auctions. A commodity search gives quantity per price, not an auction count.
    - It came in one page (`HasFullCommoditySearchResults` true) in 0.08–0.16 s.
    - Equipment through `SendSellSearchQuery` (item level and suffix cleared) returned all 7 listings in one page in
      0.16–0.41 s.
    - `IsThrottledMessageSystemReady()` never held a query back.
  - The reagents Linen Cloth 2589, Copper Ore 2770, Copper Bar 2840, Peacebloom 2447 and Light Leather 2318 are all
    **commodities**: search them with commodity searches.
  - `C_AuctionHouse.SupportsCopperValues()` = **true**: prices can carry copper.
- **[F-122]** There is **no AH cut API or constant**. Measure it from seller invoices: `GetInboxInvoiceInfo`
  (undocumented, present) → `consignment / bid`. Deposits: `CalculateCommodityDeposit` /
  `CalculateItemDeposit`; the formula is in [F-129]. `Constants.AuctionConstants.DEFAULT_AUCTION_PRICE_MULTIPLIER = 1.5`.
  The cut rate on Forever: **unmeasured**. The ReplicateItems cooldown is between 2 and 38 min ([F-121]). [Source; Probe 70374, 70425]
- **[F-123]** Professions use the modern `Blizzard_Professions` (LoadOnDemand) with Camelot overrides; Forever
  forces "show unlearned" off. `Blizzard_TradeSkillUI` and `Blizzard_CraftUI` don't exist; Enchanting uses the
  normal window. `C_TradeSkillUI`: 89 documented + 57 runtime-only functions (`GetAllRecipeIDs`,
  `GetFilteredRecipeIDs`, `GetTradeSkillLineForRecipe`, `IsTradeSkillReady`, `GetRecipeCooldown`, …). Reagents come
  from `GetRecipeSchematic(id, isRecraft)`; Blizzard's recipe tracker calls it with no profession window open.
  All Classic tradeskill and craft APIs are gone and `C_Professions` doesn't exist. `GetProfessions()` returns 7
  values (2 primary, 5 secondary). [Source; Probe 70374]
  - Blizzard's Camelot code confirms these runtime-only signatures:
    - `GetProfessionInfo(i)` → 11 values (`Camelot\Blizzard_ProfessionsFrame.lua`);
    - `GetFilteredRecipeIDs()` → a list;
    - `IsTradeSkillLinked()` → linked, linkedName;
    - `GetTradeSkillLineForRecipe(id)` → tradeSkillID, name, parentTradeSkillID. [Source 70450]
  - **`IsPlayerSpell` is only a deprecation fallback** (`Blizzard_DeprecatedSpellBook`, loaded only when the CVar
    `loadDeprecationFallbacks` is on). Use `C_SpellBook.IsSpellKnown(spellID, Enum.SpellBookSpellBank.Player)`.
    [Source 70450]
  - Measured by BuffettForever's harvest (Leatherworking, skill 49/75) [Probe 70425]:
    - **`C_TradeSkillUI.GetAllRecipeIDs()`** (no arguments) returns **every recipe of the open profession**,
      learned or not, ignoring the filters.
      - 592 for Leatherworking: its 616 SkillLineAbility spells minus 24 rank and specialization spells.
      - **Season-of-Discovery recipes are included** (Faintly Glowing Leather, Turtle Scale Gloves, Void-Touched
        Leather Gloves). Being listed is client data, not proof that a recipe can be learned on Forever.
    - `GetFilteredRecipeIDs()` returned only the 6 learned recipes ("show unlearned" is forced off) and follows
      the window's filters (skill-up, have materials, slots).
    - **`C_SpellBook.IsSpellKnown(recipeID, Enum.SpellBookSpellBank.Player)` agreed with
      `GetRecipeInfo(id).learned` for all 592**, and confirmed all 6 at login. Known recipes can be read at login
      with no profession window.
    - `GetRecipeInfo` and `GetRecipeSchematic` work with the window closed, for known and unknown recipes.
    - `GetBaseProfessionInfo().professionID` is 165, the Classic skill line.
    - The schematic yields and reagents matched the generated data (70450) for every recipe checked.
- **[F-124]** Vendors: `C_MerchantFrame.GetItemInfo(i)` → `{price (for stackCount units), stackCount,
  numAvailable, hasExtendedCost, …}`; `GetMerchantNumItems`, `GetMerchantItemID`, `GetMerchantItemLink` are
  undocumented but present; `GetMerchantItemInfo` is absent. [Source; Probe 70374]
  - **`numAvailable` = -1 means unlimited stock** (37 of 37 items at a trade-goods vendor). `price` buys
    `stackCount` units: one item cost 10c for a stack of 5. A limited item hasn't been seen yet. Harvesting from
    `MERCHANT_SHOW`/`MERCHANT_UPDATE` (0.2 s debounce) worked. [Probe 70425]
- **[F-125]** Items and item UI:
  - `C_Item.GetItemInfo`: `sellPrice` 11th, `bindType` 14th, `isCraftingReagent` 17th return.
  - Absent: `PickupItem` (use `C_Item.PickupItem`), the `ItemButtonTemplate` template (use
    `CreateFrame("ItemButton")`, `LargeItemButtonTemplate` or `SmallItemButtonTemplate`),
    `ContainerFrameItemButton_OnModifiedClick`, and the globals `GetCoinTextureString` / `GetCoinText`
    (`C_CurrencyInfo` has both). `COPPER_PER_GOLD` exists only in FrameXML.
  - Bag clicks: any modified click goes to `ContainerFrameItemButtonMixin:OnModifiedClick` →
    `HandleModifiedItemClick(link, itemLocation)` and never uses, sells or posts the item
    (`Mainline\ContainerFrame.lua`). `Bindings_Camelot.xml` binds ALT only to SELFCAST, SHOWITEMFLYOUT and
    SHOWMULTICASTFLYOUT, so Alt+click on bag items is free. Hook `HandleModifiedItemClick`, not the mixin.
    Confirmed in game: an Alt+Right-click post-hook works at the AH and at a vendor, while plain right-click still
    posts and sells. [Probe 70425]
  - `ChatEdit_InsertLink` is a deprecated alias of `ChatFrameUtil.InsertLink`. `GameTooltip:SetItemByID` can
    return false silently.

  [Source 70374]
- **[F-126]** Forever's game tables on wago.tools (build **1.60.1.70245**, read 2026-10-16) hold all recipe data:
  SpellReagents (3,300 rows), SkillLineAbility, SpellEffect (Effect 24 → `EffectItemType`, count in
  `EffectBasePointsF`), ItemSparse (`SellPrice`, `BuyPrice`, `VendorStackCount`, `Bonding`).
  - 2,340 profession recipes create an item; 2,011 have their output and every reagent in ItemSparse (1,157 with
    Classic-range output IDs). 182 enchant-only spells, 388 BoP outputs, 213 multi-output recipes (bars ×2,
    bullets ×200).
  - 1,169 outputs have IDs ≥ 200000, many with Season-of-Discovery-era names; whether they're obtainable on
    Forever is **unconfirmed**. Items missing from ItemSparse are encrypted in that build.
  - Profession skill lines are the Classic IDs (164 … 393, 129), each with a Forever child line 2937–2948.

  [Source: wago.tools DB2 70245]
  - **On 70450** (`tools/wowf/recipe_catalog.py`):
    - **1,976 complete recipes:** Leatherworking 482, Blacksmithing 419, Tailoring 405, Engineering 242, Alchemy
      181, Cooking 129, Enchanting 60, First Aid 32, Mining 17. Dropped: 331 with an output missing from
      ItemSparse, 4 with a missing reagent, 182 enchant-only, 172 with no item. All recipe rows still sit on the
      parent lines.
    - **An output count of 0 means 1:** 107 recipes, including every transmute. No recipe has two create-item
      effects, and every profession effect has DifficultyID 0.
    - `MinSkillLineRank` is **not** the skill needed to learn (it's 1 for transmutes); the trainer or recipe holds
      that. `TrivialSkillLineRankLow/High` are the yellow and grey thresholds.
    - **ID bands of the 860 recipes added after Classic:**
      - 23 Season-of-Discovery recipes (spells 400k–1M; 2 outputs seen on the AH);
      - 1 Classic spell with a new item ID;
      - **836 Forever-new recipes** (spells ≥ 1.2M, many with items ≥ 250k such as Fish Bowl, Basic Campfire,
        Camp Chair, Mana Well, plus new versions of the Classic healing potions). **117 of their outputs were on
        the beta AH** (70425), so they're crafted on Forever. Confirm the rest in game.
      - **Gathering and secondary professions craft on Forever.** One character knows these Forever-new recipes:
        - Skinning *Camp Chair* (3 Light Leather + 2 Simple Wood);
        - Cooking *Basic Campfire Kit* (1 Simple Wood);
        - First Aid *Minor Healing Potion* (Empty Vial + Mild Spices + Peacebloom). [Probe 70425]
    - **`BuyPrice / VendorStackCount` equals what a merchant charges** (37 of 37 items checked against a harvest on
      70425). ItemSparse doesn't say *which* items a vendor sells.
    - SkillLine and SkillLineAbility CSVs don't start with the `ID` column, so check the header, not
      `startswith("ID,")`.

    [Source: wago.tools DB2 70450; Probe 70425]
- **[F-127]** `SAVED_VARIABLES_TOO_LARGE(addOnName)` exists; Blizzard shows a popup (`GameEvent.HandleSavedVariablesTooLarge`).
  Whether data is dropped at load or at save is unverified on Forever, and so is the size limit. [Source 70374]
  - SavedVariables are written **without indentation**, one key per line. 2,998 price rows with one day of history
    took **556 KB**: about 185 bytes per item, plus about 33 bytes per extra day. [Probe 70425]
- **[F-128]** The beta AH is **well stocked**, not empty. On Oct 16 (Classic Beta PvP 2, Horde) a full scan saw
  61,933 listings of 2,998 items with buyouts. Linen Cloth had 8,884 units in 300 auctions.
  - **404 of the 2,998 items have IDs ≥ 200000** (210781–287063): high-ID items exist and trade on Forever (see
    [F-126]).
  - At 8 ms per frame, 61,933 rows took 0.7 s to read and 2,998 items 0.15 s to price; the scan took 5.5 s in all,
    4.7 s of it waiting for the server.
  - **Many listings are walls at one price.** 97 Azure Gustwoven Bracers were all at exactly 44s, and 12 vendor
    reagents were listed above their vendor price (Wooden Stock 50s against 2s). Asks on the beta say little about
    demand; see wowf-economics risk-and-recommendation.md.

  [Probe 70425]
- **[F-129]** **AH deposits are Classic's, with a 1s minimum per auction.**
  - The sell frame offers **2 Hours, 8 Hours and 24 Hours** (`AUCTION_DURATION_ONE/TWO/THREE`). Its default, the CVar
    `auctionHouseDurationDropdown`, was 2 (8 hours).
  - **deposit = max(1s, floor(vendor sell price × quantity ÷ 20) × {1, 4, 12})** for 2, 8 and 24 hours. That's 5%
    of the vendor price per 2 hours, floored to whole copper before the duration multiplier.
  - Verified with `CalculateCommodityDeposit` / `CalculateItemDeposit` on 20 items × 3 durations (commodities at
    100 units, items at 1), on single units, and against the sell frame: 2 Coarse Thread for 8 hours, 1s.
  - **The minimum applies per post.** Posting 2 Coarse Thread at 19c each costs a 1s deposit, lost if they don't
    sell. Items no vendor buys pay the 1s minimum.
  - Item 2657 (vendor 875c): 100c, 172c and 516c, so the floor comes before the multiplier (875 ÷ 20 = 43.75 → 43).
  - `CalculateCommodityDeposit` answers away from the AH too (1 Linen Cloth: 100).

  [Probe 70425]
- **[F-130]** **Auction House mail.**
  - The subject strings exist:
    - `AUCTION_EXPIRED_MAIL_SUBJECT` = "Auction expired: %s"
    - `AUCTION_REMOVED_MAIL_SUBJECT` = "Auction canceled: %s" (one L)
    - `AUCTION_OUTBID_MAIL_SUBJECT` = "Outbid on %s"
    - `AUCTION_SOLD_MAIL_SUBJECT` = "Auction successful: %s"
    - `AUCTION_WON_MAIL_SUBJECT` = "Auction won: %s"
  - The sender is "Horde Auction House" for a Horde character.
  - A cancelled auction's items come back as plain mail (no invoice), money 0. The mail lasts 30 days: `daysLeft`
    read 29.9995 just after it arrived.
  - Reading the header, invoice and attachments of 3 unread mails left them unread.
  - **`daysLeft` is a snapshot.** `GetServerTime() + daysLeft × 86400` moved by up to 142 s between reads.
    Blizzard's mail frame refreshes the list with `CheckInbox`, rate-limited by `C_Mail.CanCheckInbox` [Source
    70450], so reopening the mailbox can show the cached list. Within one snapshot a mail's `daysLeft` float is
    identical, so match on it before matching on time.
  - The house cut is still unmeasured ([F-122]): no sale yet.

  [Probe 70425]

## 14. Retest checklist (run on every new build)

Use `/wowfprobe full`, then `cli.py probe-report`.
1. Build, interface, `WOW_PROJECT_ID`, `[Game]`/`[Family]`, Forever preset.
2. Health and name secrecy in and out of combat. Turn on `addonCombatRestrictionsForced` to simulate combat.
3. The presence of `PlayMusic`, `PlaySoundFile`, `StopMusic`, `MuteSoundFile`, `import`, `GetSpellInfo` and `UnitAura`.
4. SavedVariables persist across a **full logout** (not just `/reload`).
5. Does a brand-new addon folder load after `/reload`, or only after a restart? ([F-024])
6. Run a real secure snippet ([F-061]).
7. `GetCurrentRegion()` value ([F-064]).
8. The documented-vs-runtime namespace diff ([F-034]).
9. Economy probes (lines in auction-house.md and professions-and-vendors.md; BuffettForever's `/bf diag` and its
   `diag` SavedVariables answer the AH ones): replicate index base and the
   ReplicateItems cooldown ([F-121]); are reagents commodities; the AH cut from a seller invoice ([F-122]);
   realm/faction keys and which characters share an AH ([F-081]); `GetRecipeSchematic` with the window closed
   and for an unknown recipe; `GetAllRecipeIDs` signature; `C_SpellBook.IsSpellKnown(recipeID)` for learned recipes
   ([F-123]); merchant `numAvailable` for unlimited stock ([F-124]). BuffettForever's `diag.harvest` answers the
   profession ones. Its `diag.deposits` checks the deposit formula against the game ([F-129]), and `diag.mail`
   the AH mail subjects and `daysLeft` ([F-130]).
10. Regenerate recipe data from the new build's tables and diff the counts against [F-126]:
    `python tools/wowf/cli.py recipe-catalog build --build <build>` (then `git diff --stat BuffettForever/Data`).
