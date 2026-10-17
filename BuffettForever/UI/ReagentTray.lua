local addonName, ns = ...

-- The tray's ten slots (laid out by UI/MainFrame.lua) wired to Crafting/Tray.lua:
-- - drag an item onto a slot (or click a slot with one on the cursor), or Alt+Right-click it in your
--   bags (Bags.lua);
-- - right-click a slot to remove it; the mouse wheel changes the quantity (Shift: 10 at a time);
-- - "Load from bags" fills the tray with your reagents; "Clear" empties it.
-- The item returns to its bag: the tray only remembers the item ID and a quantity.

local L = ns.L
local ReagentTray = {}
ns.ReagentTray = ReagentTray

local QUESTION_MARK = 134400   -- INV_Misc_QuestionMark, while an icon isn't cached
local panel
local requested = {}           -- item data asked for once each (an unknown item would never load)

local function AddFromCursor()
    local kind, itemID = GetCursorInfo()
    if kind ~= "item" or not itemID then return false end
    ClearCursor()
    if not ns.Tray.Add(itemID) then ns.Print(L["The tray is full (10 reagents)."]) end
    return true
end

local function ShowTooltip(slot)
    GameTooltip:SetOwner(slot, "ANCHOR_RIGHT")
    local entry = ns.Tray.Get(slot.index)
    if entry then
        GameTooltip:SetItemByID(entry.itemID)
        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine(L["In the tray"], tostring(entry.qty), 0.4, 0.8, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine(L["You own"], tostring(C_Item.GetItemCount(entry.itemID, true) or 0), 0.4, 0.8, 1, 1, 1, 1)
        GameTooltip:AddLine(L["Right-click: remove. Mouse wheel: quantity (Shift: 10)."], 0.6, 0.6, 0.6, true)
    else
        GameTooltip:SetText(L["Empty reagent slot"], 1, 1, 1)
        GameTooltip:AddLine(L["Drag a reagent here, or Alt+Right-click it in your bags."], nil, nil, nil, true)
    end
    GameTooltip:Show()
end

function ReagentTray.Refresh()
    if not panel then return end
    local missing = {}
    for i, slot in ipairs(panel.slots) do
        local entry = ns.Tray.Get(i)
        if entry then
            local icon = C_Item.GetItemIconByID(entry.itemID)
            if not icon and not requested[entry.itemID] then
                requested[entry.itemID] = true
                missing[#missing + 1] = entry.itemID
            end
            slot.icon:SetTexture(icon or QUESTION_MARK)
            slot.icon:Show()
            slot.count:SetText(entry.qty > 1 and tostring(entry.qty) or "")
        else
            slot.icon:Hide()
            slot.count:SetText("")
        end
        if GameTooltip:GetOwner() == slot then ShowTooltip(slot) end
    end
    if #missing > 0 then ns.Items.Load(missing, ReagentTray.Refresh) end
end

local function Setup(frame)
    panel = frame.Tray
    for _, slot in ipairs(panel.slots) do
        slot:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        slot:SetScript("OnReceiveDrag", AddFromCursor)
        slot:SetScript("OnClick", function(self, button)
            if AddFromCursor() then return end
            if button == "RightButton" then ns.Tray.Remove(self.index) end
        end)
        slot:EnableMouseWheel(true)
        slot:SetScript("OnMouseWheel", function(self, delta)
            local entry = ns.Tray.Get(self.index)
            if not entry then return end
            ns.Tray.SetQty(self.index, entry.qty + delta * (IsShiftKeyDown() and 10 or 1))
        end)
        slot:SetScript("OnEnter", ShowTooltip)
        slot:SetScript("OnLeave", GameTooltip_Hide)
    end
    panel.LoadButton:SetScript("OnClick", function()
        if ns.Tray.LoadFromBags() == 0 then ns.Print(L["No reagents in your bags."]) end
    end)
    panel.ClearButton:SetScript("OnClick", function() ns.Tray.Clear() end)
    ReagentTray.Refresh()
end

ns.On("MAIN_BUILT", Setup)
ns.On("TRAY_CHANGED", ReagentTray.Refresh)
