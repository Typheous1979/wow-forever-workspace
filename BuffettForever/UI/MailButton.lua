local addonName, ns = ...

-- The Collect button under Blizzard's mail window, right of its Inbox and Send Mail tabs (as the Scan button
-- sits under the Auction House): one click takes one mail of what BuffettForever bought (Pricing/Collect.lua),
-- inside the click (Justin, 2026-10-18). It's our own plain button parented to InboxFrame, so it shows on the
-- Inbox tab only: no hooks, nothing written into Blizzard's frames. Greyed, its tooltip says why; Blizzard's
-- Open All still takes everything.

local L = ns.L
local button

local function ShowTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(L["Collect"], 1, 1, 1)
    GameTooltip:AddLine(L["Takes the Auction House mail of what BuffettForever bought, one mail per click."], nil, nil, nil, true)
    local items = ns.Collect.Summary()
    if #items > 0 then
        GameTooltip:AddLine(" ")
        for _, e in ipairs(items) do
            GameTooltip:AddDoubleLine(C_Item.GetItemNameByID(e.itemID) or ("item " .. e.itemID),
                string.format(L["%d in the mailbox"], e.q), 1, 1, 1, 1, 1, 1)
        end
    end
    local ok, why, pick = ns.Collect.CanStart()
    GameTooltip:AddLine(" ")
    if ok then
        GameTooltip:AddDoubleLine(L["Next"], string.format("%d %s", pick.units, C_Item.GetItemNameByID(pick.itemID)
            or ("item " .. pick.itemID)), 0.4, 0.8, 1, 1, 1, 1)
    else
        GameTooltip:AddLine(why, 1, 0.3, 0.3, true)
    end
    GameTooltip:AddLine(L["It takes mail by item, so a mail of the same item you bought yourself can come too."], 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
end

local function Refresh()
    if not button then return end
    local state = ns.Collect.State()
    local n = ns.Collect.Count()
    if state == "taking" then
        button:SetText(L["Collecting..."])
    elseif n > 0 then
        button:SetText(string.format(L["Collect (%d)"], n))
    else
        button:SetText(L["Collect"])
    end
    button:SetEnabled((ns.Collect.CanStart()))
    if GameTooltip:GetOwner() == button then ShowTooltip(button) end
end

local function Build()
    if button or not InboxFrame or not MailFrame then return end
    button = CreateFrame("Button", "BuffettForeverCollectButton", InboxFrame, "UIPanelButtonTemplate")
    button:SetSize(120, 22)
    button:SetPoint("TOPRIGHT", MailFrame, "BOTTOMRIGHT", -6, -2)
    button:SetMotionScriptsWhileDisabled(true)   -- the tooltip explains why it is disabled

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\AddOns\\BuffettForever\\Media\\Icon.tga")
    icon:SetSize(16, 16)
    icon:SetPoint("LEFT", 6, 0)

    button:SetScript("OnClick", function() ns.Collect.Start() end)
    button:SetScript("OnEnter", ShowTooltip)
    button:SetScript("OnLeave", GameTooltip_Hide)
end

ns.On("MAILBOX_OPEN", function()
    Build()
    Refresh()
end)

for _, message in ipairs({ "MAILBOX_READ", "MAILBOX_CLOSED", "COLLECT_CHANGED", "BOUGHT_CHANGED", "BAGS_CHANGED" }) do
    ns.On(message, Refresh)
end
