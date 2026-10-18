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
- **Search a list as you type**, with Blizzard's search box. Example: BuffettForever `UI/ResultsList.lua` 1.0.0,
  tested on 70450.
  - `CreateFrame("EditBox", nil, pane, "SearchBoxTemplate")`, 160 × 20 at the pane's top right, as on the AddOns
    list. The template (Blizzard_SharedXML) brings the magnifying glass, the grey "Search" and the X. Enter and
    Escape leave the box, so a second Escape closes a window listed in `UISpecialFrames`.
  - The template's own OnTextChanged shows the X and the grey hint, so `HookScript("OnTextChanged", fn)`, as the
    AddOns list does. A `SetScript` must call `SearchBoxTemplate_OnTextChanged(self)` first, as the profession
    window does.
  - Filter the rows, not the data: keep the sorted list and rebuild the data provider from the rows that match, on
    every keystroke. That's instant for hundreds of rows. For a new search, pass
    `ScrollBoxConstants.DiscardScrollPosition` so the list starts at the top.
  - Match plain text: `string.find(string.lower(name), word, 1, true)` for every word, in any order. Plain, so a
    typed "(" or "%" can't break the pattern.
  - A name that isn't cached yet (`C_Item.GetItemNameByID` returns nil) can't match: filter again when the item
    data loads.
  - Keep the selection while its row is shown, else select the first row shown, so a details pane never describes a
    hidden row. Clearing the search then keeps what was picked.
  - The text survives hiding the window. BuffettForever also clears the focus in the box's OnHide, so a window
    closed while typing can't keep the keyboard.
- **Collapsible groups in one list**, as the profession window's categories. Example: BuffettForever
  `UI/ResultsList.lua` 1.0.0, tested on 70450.
  - Put header elements (`{ header = true, ... }`) and row elements in one data provider. Choose the frame per
    element with `view:SetElementFactory(function(factory, data) factory(template, initializer) end)`, and give
    each its height with `view:SetElementExtentCalculator(function(index, data) return h end)`.
    `SetElementInitializer` is a one-template wrapper around the factory.
  - The header is Blizzard's `ListHeaderVisualTemplate` (Blizzard_SharedXML `ListTemplates.xml`, loads on Forever):
    a Button with a plus/minus collapse button and a title. Use 25 px tall, as the profession window does. Then:
    - `SetTitleColor(false, NORMAL_FONT_COLOR)` for the gold title;
    - `SetHeaderText(text)`;
    - `GetCollapseButton():UpdateCollapsedState(collapsed)`;
    - on hover, `CheckHighlightTitle(true)` and `GetCollapseButton():LockHighlight()`.
  - A click flips the group's saved state and rebuilds the data provider without that group's rows. Nothing is
    re-evaluated, so it's instant. Save the collapsed groups per character; they survive a `/reload`.
  - While a search is typed, drop the groups with no match and show "n of m" in their headers.
- **Scrolling text** (a details pane):
  - `CreateFrame("ScrollFrame", nil, parent, "ScrollFrameTemplate")`; the template loads on Forever, from
    `Blizzard_SharedXML\SecureUIPanelTemplates.xml`. Its `OnLoad` attaches `self.ScrollBar`, and
    `ScrollBar:SetHideIfUnscrollable(true)` hides the bar until it's needed.
  - Put the lines on a child frame (`scroll:SetScrollChild(child)`), stack them with
    `SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -gap)`, give each a fixed width, then
    `child:SetHeight(Σ fs:GetStringHeight() + gaps)`. Example: BuffettForever `UI/DetailPanel.lua`.
- **Money in narrow columns:** `C_CurrencyInfo.GetCoinTextureString(copper, 10)`, rounded to whole silver above
  1g, so it shows two coins at most.
- **Show data, not prose.** Justin's rule for every pane: one number per row, with the explanation in the row's
  tooltip. Example: BuffettForever `UI/DetailPanel.lua`, 0.5.0, tested on 70425.
  - Each row is a Frame (width × 14) on the scroll child, holding two FontStrings:
    - a left label in `GameFontNormalSmall`; sub-rows use `GameFontHighlightSmall` and a 10 px indent;
    - a right-aligned value with `SetWordWrap(false)` and a fixed width, anchored `RIGHT`.
  - `row:SetMouseMotionEnabled(true)` plus OnEnter/OnLeave shows a `GameTooltip` (`ANCHOR_LEFT`) with the
    label as the title and the explanation lines wrapped.
  - Stack rows and text lines with one helper that anchors each region under the previous one and adds up the
    heights for the scroll child. Pool the rows, and hide them all before a refresh.
  - Colour only the exceptions: red for a loss, orange for a risk, grey for "not available".
- **A window's views: Blizzard's tabs, not home-made ones.** Justin (2026-10-17): text tabs drawn inside a pane
  get missed. Forever's own windows use two styles [Source 70450]:
  - **Bottom text tabs**, `PanelTabButtonTemplate` (Blizzard_SharedXML, the Mainline file Forever loads): the
    Auction House (Buy, Sell, Auctions), Friends, Merchant. Prefer these for views a player must discover.
    - Create them on the window and set `window.Tabs = { tab1, ... }`: the `PanelTemplates_*` helpers look there,
      then for `<WindowName>Tab<i>` globals.
    - Anchor the first `TOPLEFT` to the window's `BOTTOMLEFT` at (11, 2) on a ButtonFrameTemplate, as the
      Character frame does. `PanelTemplates_SetNumTabs(window, n)` anchors the rest;
      `PanelTemplates_SetTab(window, i)` selects one.
    - The selected tab is disabled, but the template keeps motion scripts, so tooltips still work. The template's
      own OnEnter only shows a truncated label, so hook OnEnter for yours (`ANCHOR_RIGHT`, as Blizzard's tabs do).
    - Play `SOUNDKIT.IG_CHARACTER_INFO_TAB` on click, as the Auction House does.
    - The tabs hang 30 px below the window: `window:SetClampRectInsets(0, 0, 0, -30)` keeps them on screen.
    - Example: BuffettForever `UI/ResultsList.lua` 0.7.0, tested on 70425.
    - An action tab can follow the views, such as Options opening Blizzard's settings window. Give it the next ID
      and never select it. Blizzard's settings window uses the HIGH strata, like most addon windows, so call
      `window:Lower()` after opening it, or it can open behind yours. BuffettForever 0.8.0, tested on 70425.
  - **Icon side tabs**, `LargeSideTabButtonTemplate`, on the windows Forever redesigned: Character, Professions,
    Collections, Bank, Inspect. An icon needs a hover to explain itself.
- **Items the way the profession window shows them** [Source 70450]. Forever's recipe form puts the result in a
  47 px round icon with the name beside it in its quality colour. Each reagent sits in a 39 px square slot with
  "have/need Name" beside it, white when you have enough and `DISABLED_REAGENT_COLOR` when not.
  - The round icon: `CreateFrame("Button", nil, parent, "CircularGiantItemButtonTemplate")` (Blizzard_ItemButton,
    always loaded). Set `.Icon:SetTexture(...)`, `:SetItemButtonQuality(quality)` (the Auction House's quality
    ring, which reaches about 10 px past the button, so leave a margin inside a scroll frame), and `.Count`.
  - The slot: the reagent button template lives in the load-on-demand `Blizzard_ProfessionsTemplates`, so build
    it yourself from Blizzard's art. The background is the `Professions-Slot-bg` atlas and the icon fills the
    slot. The quality frame is `PROFESSIONS_ITEM_QUALITY_ICON_BORDER_ATLASES[quality]` (Blizzard_Colors), anchored
    to the icon with 1 px extra at the bottom right.
  - Hover: `GameTooltip:SetItemByID`. Click: `HandleModifiedItemClick(link)`, so Shift-click links the item as
    on any item button.
  - Example: BuffettForever `UI/DetailPanel.lua` 0.7.0, tested on 70425.
- **A number box between two buttons**, as the profession window's Create bar ([Create All] [− n +] [Create]).
  Example: BuffettForever `UI/BuyBar.lua` 1.0.0, tested on 70450.
  - The box is Blizzard's `NumericInputSpinnerTemplate` (Blizzard_SharedXML `InputBoxTemplates.xml`). It's an EditBox
    with a − and a + button outside it, 23 px each, the − sitting 6 px off its left edge. A mouse-wheel catcher
    covers all three (Shift+wheel steps 10).
  - Leave 30 px between the box and each button beside it, as Blizzard does, so the arrows sit in the gaps.
  - `SetMinMaxValues(min, max)`, `SetValue(n)`, `SetOnValueChangedCallback(function(box, value) end)`. Set
    `clampIfInputExceedsRange` and `highlightIfInputExceedsRange` to true, as the profession window does.
  - **`SetValue` fires the callback** whenever the value changes, and so does `SetMinMaxValues` when it clamps. Set
    a flag around your own calls so the callback ignores them.
  - For a tooltip, hook OnEnter and OnLeave on both the box and `box.MouseWheelCatcher`.
  - The template's box holds 3 digits in 31 px; `SetMaxLetters(4)` with `SetWidth(38)` holds 4.
  - Add `OnEnterPressed` → `EditBox_ClearFocus` (the template has none) and clear the focus `OnHide`.
- **A disabled button that says why:** `button:SetMotionScriptsWhileDisabled(true)` keeps its OnEnter tooltip,
  so the tooltip can say what's missing ("Open the Auction House..."). BuffettForever's Scan button (0.2.0) and
  Buy button (1.0.0).

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
- Found building BuffettForever's panel (0.8.0, tested on 70425; [Source 70450] where marked):
  - A slider saves what its Slider widget holds, a 32-bit float: 6% was saved as 0.05999999865889549. Round
    before you show it, and compare with a tolerance.
  - A tooltip may be a function, called each time it shows (`Settings.InitTooltip` [Source 70450]). Use one to
    show live state, e.g. "In use: 5%, measured from 4 of your sales".
  - A dropdown option's third field is its tooltip. The control's tooltip then lists the options, with the default
    marked [Source 70450].
  - `CreateSettingsListSectionHeaderInitializer(text)` added to the layout between controls makes sections.
  - Keep the defaults in one table (BuffettForever's Core.lua `ns.DEFAULT_SETTINGS`) and pass them to
    `RegisterAddOnSetting`. A self-test can then check that each default is a choice the panel offers.
  - Don't send players to the panel's **Defaults** button: its dialog's first button, "All Settings", resets
    every game setting, not just yours [Source 70450, Blizzard_Dialogs.lua].
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
