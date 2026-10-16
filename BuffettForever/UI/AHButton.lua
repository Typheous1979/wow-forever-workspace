local addonName, ns = ...

-- A Scan button under Blizzard's Auction House frame, to the right of its Buy/Sell/Auctions
-- tabs, so a full scan is one click while the AH is open (our own window is usually closed
-- then). It's our own plain button parented to AuctionHouseFrame: no secure attributes, no
-- hooks, nothing written into Blizzard's frame. Blizzard_AuctionHouseUI is LoadOnDemand, so
-- the button is made when that addon loads (or at the first AH_OPEN if it already had).

local L = ns.L
local button

local function ShowTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("BuffettForever", 1, 1, 1)
    GameTooltip:AddLine(ns.L["by Typheous"], 0.62, 0.62, 0.62)
    GameTooltip:AddLine(L["Full scan: reads every listing on the Auction House and updates the stored prices."], nil, nil, nil, true)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(ns.Scanner.StatusText(), 1, 1, 1, true)
    GameTooltip:Show()
end

local function Refresh()
    if not button then return end
    local state = ns.Scanner.State()
    if state == "idle" then
        button:SetText(L["Scan"])
    else
        button:SetText(L["Scanning..."])
    end
    button:SetEnabled((ns.Scanner.CanScan()))
    if GameTooltip:GetOwner() == button then ShowTooltip(button) end
end

local function Build()
    if button or not AuctionHouseFrame then return end
    button = CreateFrame("Button", "BuffettForeverAHScanButton", AuctionHouseFrame, "UIPanelButtonTemplate")
    button:SetSize(110, 22)
    button:SetPoint("TOPRIGHT", AuctionHouseFrame, "BOTTOMRIGHT", -6, -2)
    button:SetMotionScriptsWhileDisabled(true)

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\AddOns\\BuffettForever\\Media\\Icon.tga")
    icon:SetSize(16, 16)
    icon:SetPoint("LEFT", 6, 0)

    button:SetScript("OnClick", function() ns.Scanner.Start() end)
    button:SetScript("OnEnter", ShowTooltip)
    button:SetScript("OnLeave", GameTooltip_Hide)
    Refresh()
end

ns.On("ADDON_LOADED", function(name)
    if name == "Blizzard_AuctionHouseUI" then Build() end
end)

ns.On("AH_OPEN", function()
    Build()
    Refresh()
end)

for _, message in ipairs({ "SCAN_PROGRESS", "SCAN_DONE", "AH_CLOSED", "READ_ONLY" }) do
    ns.On(message, Refresh)
end
