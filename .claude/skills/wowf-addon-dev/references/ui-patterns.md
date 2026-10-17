# UI patterns (Mainline API on Forever)

## Frames
- `CreateFrame(type, name, parent, template)`. Pass `nil` as the name unless you need a global, and then prefix it with the addon name.
- Frames are never garbage-collected, so pool and reuse them (`CreateFramePool`, `CreateObjectPool`).
- **Backdrops** need `"BackdropTemplate"`. Calling `SetBackdrop` with the *same* table does nothing.
- `texture:SetTexCoord(left, right, top, bottom)` takes fractions 0–1.
- Desaturate with `tex:SetDesaturated(true)`; the global `SetDesaturation` is gone.
- Fonts: `GameFontNormal`, `GameFontHighlightSmall`, `GameFontDisableSmall`, and so on.

```lua
local addonName, ns = ...

local panel = CreateFrame("Frame", addonName .. "Panel", UIParent, "BackdropTemplate")
panel:SetSize(260, 120)
panel:SetClampedToScreen(true)
panel:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
})
panel:SetBackdropColor(0, 0, 0, 0.85)

-- Movable, position saved in SavedVariables (call after ADDON_LOADED).
function ns.MakeMovable(frame, store)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        if not InCombatLockdown() then self:StartMoving() end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint(1)
        store.point, store.relPoint, store.x, store.y = point, relPoint, x, y
    end)
    frame:ClearAllPoints()
    frame:SetPoint(store.point or "CENTER", UIParent, store.relPoint or "CENTER", store.x or 0, store.y or 0)
end
```
Addon frames that you create aren't protected. You only need combat-lockdown care for secure templates, or for frames anchored to protected frames.

## Window size, lists and scrolling text (tested on 70425; BuffettForever, MusicForever)
- **Size:** at UI scale 1 on a 1080p screen, UIParent is about 1366 × 768. A main window up to about 1040 × 600 fits
  with room to spare.
- **Fonts:** WoW's default font (Friz Quadrata) has no ∞ and no en dash; they render as boxes. Write "n/a" and "to".
- **A sortable list:**
  - `CreateScrollBoxListLinearView(2, 2, 2, 2, 0)`, `view:SetElementExtent(20)`,
    `view:SetElementInitializer("Button", InitRow)`, then the WowScrollBoxList and MinimalScrollBar pair
    (BuffettForever `UI.ScrollList`).
  - Rebuild a `CreateDataProvider()` in the new order and call
    `box:SetDataProvider(dp, ScrollBoxConstants.RetainScrollPosition)`.
  - Repaint the rows in place with `box:ForEachFrame(InitRow)`, e.g. after item names load.
  - Column headings are plain Buttons that set the sort key. Give each column a fixed width, and anchor the row cells
    and the headings from the same right-hand offsets so they line up (BuffettForever `UI/ResultsList.lua`).
- **Scrolling text** (a details pane):
  - `CreateFrame("ScrollFrame", nil, parent, "ScrollFrameTemplate")`; the template loads on Forever, from
    `Blizzard_SharedXML\SecureUIPanelTemplates.xml`. Its `OnLoad` attaches `self.ScrollBar`, and
    `ScrollBar:SetHideIfUnscrollable(true)` hides the bar until it's needed.
  - Put the lines on a child frame (`scroll:SetScrollChild(child)`), stack them with
    `SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -gap)`, give each a fixed width, then
    `child:SetHeight(Σ fs:GetStringHeight() + gaps)`. Example: BuffettForever `UI/DetailPanel.lua`.
- **Money in narrow columns:** `C_CurrencyInfo.GetCoinTextureString(copper, 10)`, rounded to whole silver above
  1g, so it shows two coins at most.

## Combat lockdown queue
```lua
local queue = {}
function ns.RunOutOfCombat(fn)
    if InCombatLockdown() then queue[#queue + 1] = fn else fn() end
end
-- in your event table:
function events:PLAYER_REGEN_ENABLED()
    for i = 1, #queue do queue[i]() end
    wipe(queue)
end
```

## Settings panel (Blizzard options window)
The Settings API is in `Blizzard_Settings_Shared` [Source 70374]. The **11.0.2 argument order** for `RegisterAddOnSetting` is `(category, variable, variableKey, variableTbl, variableType, name, default)`. Build the panel **inside `ADDON_LOADED`**, after the SV table exists; bind to the table and key, never to a copied value.
```lua
function ns.BuildOptions(db)
    local category, layout = Settings.RegisterVerticalLayoutCategory("My Addon")

    local enabled = Settings.RegisterAddOnSetting(category, "MyAddon_Enabled", "enabled", db,
        Settings.VarType.Boolean, "Enable", true)
    Settings.CreateCheckbox(category, enabled, "Turn the addon on or off.")
    enabled:SetValueChangedCallback(function(setting, value) ns.Refresh() end)

    local volume = Settings.RegisterAddOnSetting(category, "MyAddon_Volume", "volume", db,
        Settings.VarType.Number, "Volume", 0.8)
    local opts = Settings.CreateSliderOptions(0, 1, 0.05)
    opts:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(v) return ("%d%%"):format(v * 100) end)
    Settings.CreateSlider(category, volume, opts, "Playback volume.")

    local mode = Settings.RegisterAddOnSetting(category, "MyAddon_Mode", "mode", db,
        Settings.VarType.String, "Mode", "zone")
    Settings.CreateDropdown(category, mode, function()
        local c = Settings.CreateControlTextContainer()
        c:Add("zone", "By zone")
        c:Add("playlist", "Playlist")
        return c:GetData()
    end, "How tracks are chosen.")

    Settings.RegisterAddOnCategory(category)
    ns.settingsCategory = category
end

-- open it (slash command / compartment click); may be restricted in combat:
function ns.OpenOptions()
    ns.RunOutOfCombat(function() Settings.OpenToCategory(ns.settingsCategory:GetID()) end)
end
```
- If `Settings.VarType` is nil, fall back to `type(default)`.
- Subcategories: `Settings.RegisterVerticalLayoutSubcategory(parent, name)`.
- Custom frames: `Settings.RegisterCanvasLayoutCategory(frame, name)`.

## Addon compartment (minimap dropdown) [Source 70374]
TOC registration needs no Lua call, only the global functions:
```
## IconTexture: Interface\Icons\INV_Misc_Note_01
## AddonCompartmentFunc: MyAddon_OnAddonCompartmentClick
## AddonCompartmentFuncOnEnter: MyAddon_OnAddonCompartmentEnter
## AddonCompartmentFuncOnLeave: MyAddon_OnAddonCompartmentLeave
```
```lua
function MyAddon_OnAddonCompartmentClick(addonName, buttonName)   -- buttonName "LeftButton"/"RightButton"
    if buttonName == "RightButton" then ns.OpenOptions() else ns.TogglePanel() end
end
function MyAddon_OnAddonCompartmentEnter(addonName, menuButtonFrame)
    GameTooltip:SetOwner(menuButtonFrame, "ANCHOR_LEFT")
    GameTooltip:SetText("My Addon")
    GameTooltip:AddLine("Left-click: toggle   Right-click: options", 1, 1, 1)
    GameTooltip:Show()
end
function MyAddon_OnAddonCompartmentLeave(addonName, menuButtonFrame)
    GameTooltip:Hide()
end
```
- Names are **case-sensitive** and must match the TOC exactly (lint TOC005).
- Dynamic label or icon: `AddonCompartmentFrame:RegisterAddon({ text = ..., icon = ..., notCheckable = true, func = function(button, menuInputData, menu) end, funcOnEnter = ..., funcOnLeave = ... })`.
- The compartment shows only when at least one addon registers.

## Slash commands
```lua
SLASH_MYADDON1 = "/myaddon"
SLASH_MYADDON2 = "/ma"
SlashCmdList["MYADDON"] = function(msg)
    local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()
    if cmd == "" or cmd == "help" then
        ns.Print("/ma toggle | options | help")
    elseif cmd == "toggle" then
        ns.TogglePanel()
    elseif cmd == "options" then
        ns.OpenOptions()
    else
        ns.Print("unknown command: " .. cmd)
    end
end
```
- The key must match exactly, aliases are numbered 1..n, and values start with `/` (lint PAT005).
- Register at file load.

## Popups
```lua
StaticPopupDialogs["MYADDON_CONFIRM_RESET"] = {
    text = "Reset all My Addon settings?",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function() ns.ResetDB() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}
StaticPopup_Show("MYADDON_CONFIRM_RESET")
```
- Use your own unique key, and never edit Blizzard's dialogs.
- `StaticPopup_Show(which, textArg1, textArg2, data)`.
- Don't define both `OnAccept` and `OnButton1`.

## Tooltips
- Add lines to Blizzard tooltips with `TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data) ... end)`, not by hooking `OnTooltipSetItem`.
- Post-calls run just before Blizzard's `tooltip:Show()` (`TooltipDataHandler.lua`), so add lines and don't call Show yourself.
- Tooltip setters are secure delegates; don't call them on Blizzard tooltips from insecure code during combat.

## Localization
```lua
-- Locales\enUS.lua (first in TOC)
local _, ns = ...
local L = setmetatable({}, { __index = function(t, k) return k end })
ns.L = L
L["Enabled"] = "Enabled"
```
Use `GetLocale()` and `## Title-deDE`. Prefer IDs over localized names for keys.

## Edit Mode note
Blizzard HUD frames are positioned by Edit Mode, with layouts saved per UI type (keyboard vs gamepad) [F-070]. Don't move Blizzard frames; place your own frames relative to `UIParent`.
