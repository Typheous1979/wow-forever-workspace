# API migration: what to write instead

The machine-readable list behind lint rule API002 is `tools/wowf/data/removed_apis.json`. Keep it and this page in sync. To check any name: `python tools/wowf/cli.py api show NAME`.

## Removed globals → replacements [F-030][F-031]
| Old (gone on Forever) | Write |
|---|---|
| `GetSpellInfo(id)` | `C_Spell.GetSpellInfo(id)` → **table** `{name, iconID, originalIconID, castTime, minRange, maxRange, spellID}` or nil |
| `GetSpellTexture`, `GetSpellCooldown`, `GetSpellCharges`, `GetSpellDescription`, `IsUsableSpell`, `GetSpellCount` | `C_Spell.GetSpellTexture/GetSpellCooldown/GetSpellCharges/GetSpellDescription/IsSpellUsable/GetSpellCastCount` |
| `GetSpellBookItemName`, `GetNumSpellTabs`, `GetSpellTabInfo` | `C_SpellBook.GetSpellBookItemName/GetNumSpellBookSkillLines/GetSpellBookSkillLineInfo` |
| `GetItemInfo(id)` | `C_Item.GetItemInfo(id)` → **18 values** (name, link, quality, itemLevel, minLevel, type, subType, stackCount, equipLoc, texture, sellPrice, classID, subclassID, bindType, expansionID, setID, isCraftingReagent, itemDescription) or nil |
| `GetItemCount`, `GetItemIcon`, `GetItemInfoInstant`, `GetItemQualityColor`, `IsEquippedItem`, `GetItemSpell`, `IsUsableItem` | `C_Item.*` (`GetItemIconByID` for icons) |
| `GetItemCooldown`, `GetContainerItemInfo`, `GetContainerNumSlots`, `PickupContainerItem` | `C_Container.*` |
| `GetAddOnMetadata`, `IsAddOnLoaded`, `LoadAddOn`, `GetAddOnInfo`, `GetNumAddOns`, `EnableAddOn` | `C_AddOns.*`. `GetAddOnMetadata` **errors** on an unknown addon name, so pcall it for optional dependencies |
| `UnitAura`, `UnitBuff`, `UnitDebuff` | `C_UnitAuras.*`. Aura data is secret when restricted; don't drive combat logic from it |
| `GetTalentInfo`, `GetNumTalentTabs` | `C_Traits` / `C_ClassTalents` (Forever talents use the trait system) |
| `GetNumSkillLines`, `GetSkillLineInfo` | `C_SkillInfo` (Forever-only) — verify with `wowf-api find C_SkillInfo` |
| `GetMouseFocus` | `GetMouseFoci()` (list) |
| `EasyMenu`, `UIDropDownMenu_*` menus | `MenuUtil.CreateContextMenu(owner, function(owner, root) ... end)` |
| `SendAddonMessage`, `RegisterAddonMessagePrefix` | `C_ChatInfo.SendAddonMessage/RegisterAddonMessagePrefix` |
| `GetCoinTextureString`, `GetCoinText` | `C_CurrencyInfo.GetCoinTextureString/GetCoinText` |
| `QueryAuctionItems` (incl. getAll), `GetAuctionItemInfo`, `GetNumAuctionItems`, `GetAuctionItemLink`, `CanSendAuctionQuery` | full scan: `C_AuctionHouse.ReplicateItems` + `GetNumReplicateItems`/`GetReplicateItemInfo`; one item: `MakeItemKey` + `SendSearchQuery` + `Get*SearchResultInfo`; throttle: `IsThrottledMessageSystemReady` (auction-house.md) [F-120] |
| `PostAuction`, `StartAuction`, `PlaceAuctionBid`, `CalculateAuctionDeposit`, `CloseAuctionHouse` | `C_AuctionHouse.PostItem/PostCommodity/PlaceBid` (restricted: player-initiated only), `CalculateCommodityDeposit/CalculateItemDeposit`, `C_AuctionHouse.CloseAuctionHouse` |
| `GetNumTradeSkills`, `GetTradeSkillInfo`, `GetTradeSkillReagentInfo`, `GetTradeSkillItemLink`, `GetCraftInfo`, `DoTradeSkill`, `DoCraft` | `C_TradeSkillUI.GetAllRecipeIDs` (runtime-only), `GetRecipeInfo`, `GetRecipeSchematic(id, false)`, `GetRecipeOutputItemData`, `CraftRecipe` (professions-and-vendors.md) [F-123] |
| `GetMerchantItemInfo` | `C_MerchantFrame.GetItemInfo(i)` → table; `price` buys `stackCount` units [F-124] |
| `PickupItem` | `C_Item.PickupItem` [F-125] |
| `ChatEdit_InsertLink` | `ChatFrameUtil.InsertLink` (the old name is a deprecated alias) |
| `PlayVocalErrorSoundID` | `C_Sound.PlayVocalErrorSound` |
| `SetDesaturation(tex, on)` | `tex:SetDesaturated(on)` |
| `InterfaceOptions_AddCategory`, `InterfaceOptionsFrame_OpenToCategory` | the Settings API (ui-patterns.md) |
| `CombatLogGetCurrentEventInfo`, `COMBAT_LOG_EVENT_UNFILTERED` | **nothing**; drop the feature [F-070] |
| `C_SuperTrack.SetSuperTrackedUserWaypoint` | `C_Map.SetUserWaypoint(UiMapPoint...)` (below) |
| `ChatFrame_OpenChat`, `ChatEdit_ActivateChat` | don't; let the client open chat. Shift-click links go through `HandleModifiedItemClick(link)` |
| `GetCVar`/`SetCVar` globals | prefer `C_CVar.GetCVar`/`C_CVar.SetCVar` |

"Deprecated shim" globals still load on Forever (from `Blizzard_Deprecated`, mainline family). Lint downgrades them to warnings, but prefer the replacement.

## Async spell and item data
Lookups return nil until the record is cached; that doesn't mean the thing is missing.
```lua
local addonName, ns = ...
local pendingItems = {}

local function ShowItem(itemID)
    local name, link = C_Item.GetItemInfo(itemID)
    if not name then
        pendingItems[itemID] = true
        C_Item.RequestLoadItemDataByID(itemID)     -- also accepts an item link
        return
    end
    ns.Print(link)
end

local events = {}
function events:ITEM_DATA_LOAD_RESULT(itemID, success)
    if pendingItems[itemID] then
        pendingItems[itemID] = nil
        if success then ShowItem(itemID) end      -- success=false: server refused this ID
    end
end

function events:SPELL_DATA_LOAD_RESULT(spellID, success)
    local info = C_Spell.GetSpellInfo(spellID)    -- success=false can still mean partial data
    if info then ns.Print(info.name) end
end
-- C_Spell.RequestLoadSpellData(spellID) to request.
```
`Item:CreateFromItemID(id):ContinueOnItemLoad(fn)` (ItemMixin) and `Spell:CreateFromSpellID(id):ContinueOnSpellLoad(fn)` are FrameXML helpers that do the same thing.

## Waypoints (not the protected super-track call)
```lua
local mapID = C_Map.GetBestMapForUnit("player")
if mapID and C_Map.CanSetUserWaypointOnMap(mapID) then
    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if pos then
        C_Map.SetUserWaypoint(UiMapPoint.CreateFromVector2D(mapID, pos))
    end
end
-- or: C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapID, 0.42, 0.65))
```

## Game rules and preset [F-014]
```lua
local function ExperiencePreset()
    if not (C_GameRules and C_GameRules.GetForeverExperiencePreset) then return "unavailable" end
    local p = C_GameRules.GetForeverExperiencePreset()        -- nilable
    if p == Enum.ForeverExperiencePreset.Classic then return "Classic" end
    if p == Enum.ForeverExperiencePreset.Modern then return "Modern" end
    return "unknown"
end
-- C_GameRules.IsHardcoreActive(), C_GameRules.IsSelfFoundAllowed()
-- Events: GAME_RULES_CHANGED, ACTIVE_GAME_MODE_UPDATED
```

## Units
- **Faction test:** `UnitIsEnemy` and `UnitCanAttack` mean "attackable right now" (false for unflagged enemies, sanctuaries, other shards). Use this instead:
  ```lua
  local mine, theirs = UnitFactionGroup("player"), UnitFactionGroup(unit)
  local opposite = mine and theirs and mine ~= theirs
  ```
- **Names:** see [F-080]. Key data by GUID for your own group, or by full "First Surname" for players. Never key on `UnitFullName` name-realm.
- **Nameplates [F-063]:** after `NAME_PLATE_UNIT_ADDED(unit)`, defer reads with `C_Timer.After(0, ...)`, or sweep `nameplate1..40`. Rare-tamed hunter pets keep the rare classification, so filter `UnitPlayerControlled(unit)`.

## Unit events (instead of the combat log)
| Want | Use |
|---|---|
| player health/power | `RegisterUnitEvent("UNIT_HEALTH", "player")`, `UNIT_MAXHEALTH`, `UNIT_POWER_UPDATE` |
| casts | `UNIT_SPELLCAST_START/STOP/SUCCEEDED/FAILED/INTERRUPTED` (payload can be secret for others) |
| combat state | `PLAYER_REGEN_DISABLED` / `PLAYER_REGEN_ENABLED` |
| boss pull | `ENCOUNTER_START` / `ENCOUNTER_END` |
| zone | `ZONE_CHANGED`, `ZONE_CHANGED_INDOORS`, `ZONE_CHANGED_NEW_AREA`, `PLAYER_ENTERING_WORLD` |
| Forever extras | `PLAYER_SWING`, `DIEL_CYCLE_CHANGED(isDayTime)`, `WEATHER_CHANGED`, `GAME_RULES_CHANGED` |

Check any event name with `python tools/wowf/cli.py api events REGEX`. Lint API007 flags unknown events.

## Menus
```lua
MenuUtil.CreateContextMenu(ownerFrame, function(owner, root)
    root:CreateTitle("My Addon")
    root:CreateButton("Do thing", function() ns.DoThing() end)
    root:CreateCheckbox("Enabled", function() return ns.db.enabled end, function() ns.db.enabled = not ns.db.enabled end)
end)
-- Extend Blizzard menus: Menu.ModifyMenu("MENU_UNIT_PLAYER", function(owner, root, contextData) ... end)
```
