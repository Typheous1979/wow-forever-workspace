local addonName, ns = ...

-- The tray's 25 slots (laid out by UI/MainFrame.lua) wired to Crafting/Tray.lua:
-- - drag an item onto a slot (or click a slot with one on the cursor), or Alt+Right-click it in your
--   bags (Bags.lua);
-- - right-click a slot to remove it; the mouse wheel changes the quantity (Shift: 10 at a time);
-- - "Load from bags" fills the tray with your reagents; "Clear" empties it.
-- The item returns to its bag: the tray only remembers the item ID and a quantity. Each slot shows where its
-- units are (Tray.SlotState; Justin, 2026-10-18): an envelope with the units BuffettForever bought that are
-- still in the mailbox, a grey icon when crafting can't use any yet, and an orange count when the tray counts
-- more than you have anywhere. While anything is in the mailbox, a line under the buttons says so.

local L = ns.L
local UI = ns.UI
local ReagentTray = {}
ns.ReagentTray = ReagentTray

local QUESTION_MARK = 134400   -- INV_Misc_QuestionMark, while an icon isn't cached
local ORANGE_R, ORANGE_G, ORANGE_B = 1, 0.6, 0.2
local LABEL_R, LABEL_G, LABEL_B = 0.4, 0.8, 1
local panel
local requested = {}           -- item data asked for once each (an unknown item would never load)

local function AddFromCursor()
    local kind, itemID = GetCursorInfo()
    if kind ~= "item" or not itemID then return false end
    ClearCursor()
    if not ns.Tray.Add(itemID) then ns.Print(string.format(L["The tray is full (%d reagents)."], ns.Tray.SIZE)) end
    return true
end

-- Where an item is: the bags, the banks, what's ours in the mailbox, and the slot's state.
local function Where(entry)
    local bags = C_Item.GetItemCount(entry.itemID) or 0
    local bank = ns.Tray.BankCount(entry.itemID)
    local mail = ns.Collect.InMail(entry.itemID)
    local bankUsable = ns.Tray.BankUsable()
    local usable, faded, short = ns.Tray.SlotState(entry.qty, bags, bank, mail, bankUsable)
    return { bags = bags, bank = bank, mail = mail, bankUsable = bankUsable, usable = usable, faded = faded, short = short }
end

local function ShowTooltip(slot)
    GameTooltip:SetOwner(slot, "ANCHOR_RIGHT")
    local entry = ns.Tray.Get(slot.index)
    if entry then
        local w = Where(entry)
        GameTooltip:SetItemByID(entry.itemID)
        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine(L["In the tray"], tostring(entry.qty), LABEL_R, LABEL_G, LABEL_B, 1, 1, 1)
        GameTooltip:AddDoubleLine(L["In your bags"], tostring(w.bags), LABEL_R, LABEL_G, LABEL_B, 1, 1, 1)
        GameTooltip:AddDoubleLine(L["In your bank"], tostring(w.bank), LABEL_R, LABEL_G, LABEL_B, 1, 1, 1)
        if w.mail > 0 then
            GameTooltip:AddDoubleLine(L["In your mailbox"], tostring(w.mail), LABEL_R, LABEL_G, LABEL_B, 1, 1, 1)
        end
        if w.short then
            GameTooltip:AddLine(string.format(L["The tray counts %d, but you have %d: you'd be short when you craft."],
                entry.qty, w.bags + w.bank + w.mail), ORANGE_R, ORANGE_G, ORANGE_B, true)
        end
        if w.mail > 0 then
            GameTooltip:AddLine(L["Bought through BuffettForever, still in the mailbox: Collect, under the mail window, takes it."],
                0.6, 0.6, 0.6, true)
        end
        if w.faded then
            GameTooltip:AddLine(w.bankUsable and L["None in your bags or bank yet: crafting can't use it."]
                or L["None in your bags yet: crafting uses only the bags."], 0.6, 0.6, 0.6, true)
        end
        GameTooltip:AddLine(L["Right-click: remove. Mouse wheel: quantity (Shift: 10)."], 0.6, 0.6, 0.6, true)
    else
        GameTooltip:SetText(L["Empty reagent slot"], 1, 1, 1)
        GameTooltip:AddLine(L["Drag a reagent here, or Alt+Right-click it in your bags."], nil, nil, nil, true)
    end
    GameTooltip:Show()
end

-- The tray's reagents still in the mailbox: { { itemID, mail } }.
local function InTheMail()
    local list = {}
    for _, entry in ipairs(ns.Tray.Entries()) do
        local mail = ns.Collect.InMail(entry.itemID)
        if mail > 0 then list[#list + 1] = { itemID = entry.itemID, mail = mail } end
    end
    return list
end

local function ShowMailTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(L["In your mailbox"], 1, 1, 1)
    for _, e in ipairs(InTheMail()) do
        GameTooltip:AddDoubleLine(C_Item.GetItemNameByID(e.itemID) or ("item " .. e.itemID), tostring(e.mail), 1, 1, 1, 1, 1, 1)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L["The Auction House mails what you buy. Collect, under the mail window, takes what BuffettForever bought; Blizzard's Open All takes everything."],
        0.6, 0.6, 0.6, true)
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
            local w = Where(entry)
            slot.icon:SetTexture(icon or QUESTION_MARK)
            slot.icon:SetDesaturated(w.faded)
            slot.icon:Show()
            slot.count:SetText((entry.qty > 1 or w.short) and tostring(entry.qty) or "")
            if w.short then
                slot.count:SetTextColor(ORANGE_R, ORANGE_G, ORANGE_B)
            else
                slot.count:SetTextColor(1, 1, 1)
            end
            slot.mail:SetShown(w.mail > 0)
            slot.mailCount:SetText(w.mail > 0 and tostring(w.mail) or "")
        else
            slot.icon:Hide()
            slot.icon:SetDesaturated(false)
            slot.count:SetText("")
            slot.mail:Hide()
            slot.mailCount:SetText("")
        end
        if GameTooltip:GetOwner() == slot then ShowTooltip(slot) end
    end
    local inMail = #InTheMail()
    panel.Mail:SetShown(inMail > 0)
    panel.Hint:SetShown(inMail == 0)
    if inMail > 0 then
        panel.Mail.Text:SetText(UI.MailIconText(12) .. " " .. string.format(inMail == 1 and L["%d reagent in your mailbox"]
            or L["%d reagents in your mailbox"], inMail))
        if GameTooltip:GetOwner() == panel.Mail then ShowMailTooltip(panel.Mail) end
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
    panel.Mail:SetScript("OnEnter", ShowMailTooltip)
    panel.Mail:SetScript("OnLeave", GameTooltip_Hide)
    panel.LoadButton:SetScript("OnClick", function()
        if ns.Tray.LoadFromBags() == 0 then ns.Print(L["No reagents in your bags."]) end
    end)
    panel.ClearButton:SetScript("OnClick", function() ns.Tray.Clear() end)
    ReagentTray.Refresh()
end

ns.On("MAIN_BUILT", Setup)
for _, message in ipairs({ "TRAY_CHANGED", "BAGS_CHANGED", "MAILBOX_READ", "BOUGHT_CHANGED" }) do
    ns.On(message, ReagentTray.Refresh)
end
