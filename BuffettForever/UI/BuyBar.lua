local addonName, ns = ...

-- The Buy bar at the bottom of the details pane, in the Profession profits view (Justin, 2026-10-17),
-- laid out like the profession window's Create bar: a status line over [Best] [- n +] [Buy].
-- - Crafts (Blizzard's NumericInputSpinnerTemplate): the selected recipe's batch. The slots, the cost, the
--   profit and the row follow it (ResultsList.SetCrafts) until another recipe or view is picked; it starts
--   at what the tray allows.
-- - Best: the best batch (the reagents and the market, as the Best batch row), lowered to what your gold
--   buys (Evaluator.AffordableBatch).
-- - Buy: what the recipe still needs after the tray, from the AH and vendors (Evaluator.ShoppingList), in
--   its tooltip. At the Auction House, the reagents to buy there whose prices are over a minute old are
--   searched again when the recipe shows ("Checking prices"); each stored price re-evaluates the list
--   (PRICES_CHANGED). This pass lists the purchases; buying them comes in the next one.
-- The status line sums up what's left to buy.

local L = ns.L
local UI = ns.UI
local Money = ns.Money
local BuyBar = {}
ns.BuyBar = BuyBar

local HEIGHT = 48           -- the status line over the buttons
local MAX_CRAFTS = 200      -- the box goes higher only when the tray allows more
local MAX_LETTERS = 4       -- the tray holds at most 9,999 of an item
local FRESH = 60            -- seconds: a price this recent isn't searched again, nor an item searched this recently
local GREEN, RED, GREY = "|cff33ff33", "|cffff5533", "|cff999999"
local LIMIT_TEXT = { reagents = "reagents", market = "market", none = "no limit" }

local bar, current
local silent = false   -- set while the bar sets the Crafts box itself
local searched = {}    -- [itemID] = GetTime() of the bar's last search for it, this visit to the AH
local pending = {}     -- [itemID] = true while that search is out
local problems = {}    -- [itemID] = why the last search found nothing to buy

local function Name(itemID)
    return C_Item.GetItemNameByID(itemID) or ("item " .. itemID)
end

-- The bar serves Profession profits recipes (their costs count only the tray; ResultsList.SetCrafts).
local function Applies(r)
    return r ~= nil and not r.flip and r.view == "professions" and r.ctx ~= nil
end

local function Checking(r)
    for _, line in ipairs(r.lines) do
        if pending[line.itemID] then return true end
    end
    return false
end

-- At the AH: search again the reagents bought there (or with no price yet) whose stored price is over FRESH
-- seconds old, each at most once per FRESH seconds (a search that finds none stores nothing).
local function CheckPrices(r)
    if not ns.ahOpen or not ns.Main.IsShown() then return end
    local now = GetTime()
    for _, line in ipairs(r.lines) do
        local itemID = line.itemID
        if line.rest > 0 and line.source ~= "vendor" and not pending[itemID]
            and (not searched[itemID] or now - searched[itemID] > FRESH) then
            local _, age = ns.PriceDB.Get(itemID)
            if not age or age > FRESH then
                searched[itemID], pending[itemID] = now, true
                ns.Search.Request(itemID, nil, function(id, result, problem)
                    pending[id] = nil
                    problems[id] = not result and problem or nil
                    BuyBar.Refresh()
                end)
            end
        end
    end
end

-- "To buy: AH 1g 20s, vendor 40c, 1 short", or what's going on.
local function StatusText(r, list)
    if Checking(r) then return GREY .. L["Checking prices at the Auction House..."] .. "|r" end
    if #list.ah + #list.vendor + #list.short == 0 then return GREEN .. L["Everything is in the tray."] .. "|r" end
    local parts = {}
    if #list.ah > 0 then parts[#parts + 1] = string.format(L["AH %s"], Money.Compact(list.ahCost)) end
    if #list.vendor > 0 then parts[#parts + 1] = string.format(L["vendor %s"], Money.Compact(list.vendorCost)) end
    if #list.short > 0 then parts[#parts + 1] = RED .. string.format(L["%d short"], #list.short) .. "|r" end
    return NORMAL_FONT_COLOR:WrapTextInColorCode(L["To buy:"]) .. " " .. table.concat(parts, ", ")
end

function BuyBar.Refresh()
    if not bar then return end
    local r = current
    local shown = Applies(r)
    bar:SetShown(shown)
    ns.DetailPanel.SetBottomInset(shown and HEIGHT + 4 or 0)
    if not shown then return end
    silent = true
    bar.Crafts:SetMinMaxValues(1, math.max(MAX_CRAFTS, r.crafts))
    bar.Crafts:SetValue(r.crafts)
    silent = false
    bar.Status:SetText(StatusText(r, ns.Evaluator.ShoppingList(r)))
    bar.Best:SetEnabled(r.batch == nil or r.batch.size ~= nil)
    bar.Buy:SetEnabled(false)   -- this pass lists the purchases only
end

-- ---------------------------------------------------------------- tooltips

local function Line(e)
    return string.format("%d %s", e.qty, Name(e.itemID))
end

-- How old the AH prices are: the oldest one bought there.
local function PriceAge(r, list)
    if Checking(r) then return L["Checking prices at the Auction House..."] end
    local oldest
    for _, e in ipairs(list.ah) do
        local _, age = ns.PriceDB.Get(e.itemID)
        if age and (not oldest or age > oldest) then oldest = age end
    end
    return oldest and string.format(L["Prices from %s ago."], ns.FormatAge(oldest)) or nil
end

local function Section(title, total)
    GameTooltip:AddLine(" ")
    if total then
        GameTooltip:AddDoubleLine(title, Money.Format(total), 1, 0.82, 0, 1, 1, 1)
    else
        GameTooltip:AddLine(title, 1, 0.82, 0)
    end
end

-- What Buy gets: the AH lines and their prices' age, the vendor lines, what can't be bought, and what the
-- tray covers. Disabled, it still explains (motion scripts while disabled).
local function BuyTooltip(self)
    local r = current
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(L["Buy what's missing"], 1, 1, 1)
    if not Applies(r) then
        GameTooltip:Show()
        return
    end
    if not ns.ahOpen then
        GameTooltip:AddLine(L["Open the Auction House (talk to an auctioneer) to buy what's missing."], 1, 0.33, 0.2, true)
    end
    if not r.known then GameTooltip:AddLine(L["You don't know this recipe yet."], 1, 0.33, 0.2, true) end
    local list = ns.Evaluator.ShoppingList(r)
    if #list.ah > 0 then
        Section(L["Auction House"], list.ahCost)
        for _, e in ipairs(list.ah) do
            local problem = problems[e.itemID]
            if problem then
                GameTooltip:AddDoubleLine(Line(e), problem, 1, 1, 1, 1, 0.33, 0.2)
            else
                GameTooltip:AddDoubleLine(Line(e), Money.Format(e.cost), 1, 1, 1, 1, 1, 1)
            end
        end
        local age = PriceAge(r, list)
        if age then GameTooltip:AddLine(age, 0.6, 0.6, 0.6, true) end
    end
    if #list.vendor > 0 then
        Section(L["Vendor"], list.vendorCost)
        for _, e in ipairs(list.vendor) do GameTooltip:AddDoubleLine(Line(e), Money.Format(e.cost), 1, 1, 1, 1, 1, 1) end
    end
    if #list.short > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(L["Can't be bought"], 1, 0.33, 0.2)
        for _, e in ipairs(list.short) do
            local why = e.available and string.format(L["only %d listed"], e.available) or problems[e.itemID] or L["no price"]
            GameTooltip:AddDoubleLine(Line(e), why, 1, 1, 1, 1, 0.33, 0.2)
        end
    end
    if #list.tray > 0 then
        Section(L["From your tray"])
        for _, e in ipairs(list.tray) do GameTooltip:AddLine(Line(e), 1, 1, 1) end
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L["Bags and bank don't count in this tab: put what you have in the tray."], 0.6, 0.6, 0.6, true)
    GameTooltip:AddLine(L["This test build lists what Buy will buy; buying comes in the next one."], 1, 0.6, 0.2, true)
    GameTooltip:Show()
end

local function BestTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(L["Best"], 1, 1, 1)
    GameTooltip:AddLine(L["Sets the crafts to the best batch (the reagents and the market), within your gold."], nil, nil, nil, true)
    local r = current
    if Applies(r) then
        local n, byGold = ns.Evaluator.AffordableBatch(r, GetMoney())
        local a = r.batch
        if n then
            GameTooltip:AddDoubleLine(L["Best batch"], a.limit == "none" and L["no limit"]
                or string.format("%d (%s)", a.size, L[LIMIT_TEXT[a.limit]]), 1, 0.82, 0, 1, 1, 1)
            if byGold then GameTooltip:AddDoubleLine(L["Your gold buys"], tostring(n), 1, 0.82, 0, 1, 1, 1) end
        else
            GameTooltip:AddLine(L["No batch can be priced: a reagent or the result has no price."], 1, 0.33, 0.2, true)
        end
    end
    GameTooltip:Show()
end

local function CraftsTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(L["Crafts"], 1, 1, 1)
    GameTooltip:AddLine(L["How many to make: the reagents, the cost and the profit follow it."], nil, nil, nil, true)
    GameTooltip:AddLine(L["It starts at what your tray allows, and does again when you pick another recipe."], nil, nil, nil, true)
    GameTooltip:Show()
end

-- ---------------------------------------------------------------- build

local function OnBest()
    local r = current
    if not Applies(r) then return end
    local n = ns.Evaluator.AffordableBatch(r, GetMoney())
    if n then ns.ResultsList.SetCrafts(r.recipe.recipeID, n) end
end

-- Laid out as the profession window's Create bar: the box between the buttons, 30 px from each, so its
-- arrows sit in the gaps.
local function Build(frame)
    bar = CreateFrame("Frame", nil, frame.Details)
    bar:SetPoint("BOTTOMLEFT", 8, 6)
    bar:SetPoint("BOTTOMRIGHT", -8, 6)
    bar:SetHeight(HEIGHT)
    bar:Hide()
    local divider = bar:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(1, 1, 1, 0.12)
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT")
    divider:SetPoint("TOPRIGHT")
    bar.Status = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.Status:SetPoint("TOPLEFT", 2, -7)
    bar.Status:SetPoint("TOPRIGHT", -2, -7)
    bar.Status:SetJustifyH("LEFT")
    bar.Status:SetWordWrap(false)

    bar.Buy = UI.Button(bar, L["Buy"], 80)
    bar.Buy:SetPoint("BOTTOMRIGHT")
    bar.Buy:SetMotionScriptsWhileDisabled(true)   -- the tooltip says what it needs
    bar.Buy:SetScript("OnEnter", BuyTooltip)
    bar.Buy:SetScript("OnLeave", GameTooltip_Hide)

    local crafts = CreateFrame("EditBox", nil, bar, "NumericInputSpinnerTemplate")
    crafts.clampIfInputExceedsRange, crafts.highlightIfInputExceedsRange = true, true   -- as the profession window's
    crafts:SetMaxLetters(MAX_LETTERS)
    crafts:SetWidth(38)
    crafts:SetPoint("RIGHT", bar.Buy, "LEFT", -30, 0)
    crafts:SetMinMaxValues(1, MAX_CRAFTS)
    crafts:SetOnValueChangedCallback(function(_, value)
        if silent or not Applies(current) or value < 1 then return end
        ns.ResultsList.SetCrafts(current.recipe.recipeID, value)
    end)
    crafts:SetScript("OnEnterPressed", EditBox_ClearFocus)
    crafts:HookScript("OnHide", EditBox_ClearFocus)
    for _, f in ipairs({ crafts, crafts.MouseWheelCatcher }) do   -- the catcher covers the box and its arrows
        f:HookScript("OnEnter", CraftsTooltip)
        f:HookScript("OnLeave", GameTooltip_Hide)
    end
    bar.Crafts = crafts

    bar.Best = UI.Button(bar, L["Best"], 56, OnBest)
    bar.Best:SetPoint("RIGHT", crafts, "LEFT", -32, 0)
    bar.Best:SetMotionScriptsWhileDisabled(true)
    bar.Best:SetScript("OnEnter", BestTooltip)
    bar.Best:SetScript("OnLeave", GameTooltip_Hide)
end

ns.On("MAIN_BUILT", Build)

ns.On("DETAILS_SHOWN", function(result)
    current = result
    if Applies(result) then CheckPrices(result) end
    BuyBar.Refresh()
end)

-- Opening the AH, or the window at the AH, checks the shown recipe's prices.
for _, message in ipairs({ "AH_OPEN", "MAIN_SHOWN" }) do
    ns.On(message, function()
        if Applies(current) then CheckPrices(current) end
        BuyBar.Refresh()
    end)
end

ns.On("AH_CLOSED", function()   -- Search has already answered what was out
    wipe(searched)
    wipe(pending)
    wipe(problems)
    BuyBar.Refresh()
end)
