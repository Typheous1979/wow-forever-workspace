local addonName, ns = ...

-- The Buy bar at the bottom of the details pane, laid out like the profession window's Create bar: a status
-- line over [Best] [- n +] [Buy] (Justin, 2026-10-17). Purchases go through Pricing/Buy.lua.
-- In Profession profits:
-- - Crafts (Blizzard's NumericInputSpinnerTemplate): the selected recipe's batch. The slots, the cost, the
--   profit and the row follow it (ResultsList.SetCrafts) until another recipe or view is picked; it starts
--   at what the tray allows.
-- - Best: the best batch (the reagents and the market, as the Best batch row), lowered to what your gold
--   buys (Evaluator.AffordableBatch). While a price is open it's Cancel.
-- - Buy: what the recipe still needs after the tray (Evaluator.ShoppingList), one line at a time: at the
--   Auction House its AH lines (Buy asks for the price, Confirm buys it), at a vendor its vendor lines (in
--   whole stacks; one click, or Confirm at 150g or more). What's bought goes into the tray and the next line
--   comes up. At the AH, the reagents bought there whose prices are over a minute old are searched again when
--   the recipe shows ("Checking prices").
-- In AH flips: Buy only. The flip's item is searched when it shows; a commodity is bought as one quote for
-- every unit still below what a vendor pays, gear one auction at a time (Buy shows it, Confirm buys it).
-- If Forever blocks buying, or a reagent isn't a commodity, Buy becomes Search: the name goes into
-- Blizzard's search box.

local L = ns.L
local UI = ns.UI
local Money = ns.Money
local BuyBar = {}
ns.BuyBar = BuyBar
local events = ns.events

local HEIGHT = 48           -- the status line over the buttons
local MAX_CRAFTS = 200      -- the box goes higher only when the tray allows more
local MAX_LETTERS = 4       -- the tray holds at most 9,999 of an item
local FRESH = 60            -- seconds: a price this recent isn't searched again, nor an item searched this recently
local FRESH_QUOTE = 120     -- seconds: a price this recent holds a quote to Blizzard's 5% rule
local COUNTDOWN = 10        -- the last seconds of a quote, counted down (Blizzard's buy dialog does the same)
local GREEN, ORANGE, RED, GREY = "|cff33ff33", "|cffff9933", "|cffff5533", "|cff999999"
local LIMIT_TEXT = { reagents = "reagents", market = "market", none = "no limit" }

local bar, current
local silent = false   -- set while the bar sets the Crafts box itself
local searched = {}    -- [itemID] = GetTime() of the bar's last search for it, this visit to the AH
local pending = {}     -- [itemID] = true while that search is out; "eval" until the list re-evaluates on its price
local problems = {}    -- [itemID] = why the last search found nothing to buy
local auctions = {}    -- [itemID] = a gear item's auctions from the last search, cheapest first

local function Name(itemID)
    return C_Item.GetItemNameByID(itemID) or ("item " .. itemID)
end

local function Icon(itemID)
    local icon = C_Item.GetItemIconByID(itemID)
    return icon and string.format("|T%s:14:14|t ", icon) or ""
end

local function IsRecipe(r)
    return r ~= nil and not r.flip and r.view == "professions" and r.ctx ~= nil
end

local function IsFlip(r)
    return r ~= nil and r.flip == true
end

local function Applies(r)
    return IsRecipe(r) or IsFlip(r)
end

local function Checking(r)
    if IsFlip(r) then return pending[r.recipe.output] ~= nil end
    for _, line in ipairs(r.lines) do
        if pending[line.itemID] then return true end
    end
    return false
end

local function SearchItem(itemID)
    searched[itemID], pending[itemID] = GetTime(), true
    ns.Search.Request(itemID, nil, function(id, result, problem)
        pending[id] = result and "eval" or nil   -- Buy waits for the estimate at the new price
        problems[id] = not result and problem or nil
        BuyBar.Refresh()
    end)
end

local function Due(itemID)
    return not pending[itemID] and (not searched[itemID] or GetTime() - searched[itemID] > FRESH)
end

-- At the AH: a recipe's reagents bought there (or with no price yet) whose stored price is over FRESH seconds
-- old, each at most once per FRESH seconds (a search that finds none stores nothing); a flip's item at once,
-- for what's still below the vendor's price and, for gear, its auctions.
local function CheckPrices(r)
    if not ns.ahOpen or not ns.Main.IsShown() then return end
    if IsFlip(r) then
        if Due(r.recipe.output) then SearchItem(r.recipe.output) end
        return
    end
    for _, line in ipairs(r.lines) do
        local itemID = line.itemID
        if line.rest > 0 and line.source ~= "vendor" and Due(itemID) then
            local _, age = ns.PriceDB.Get(itemID)
            if not age or age > FRESH then SearchItem(itemID) end
        end
    end
end

-- Blizzard's search box instead of a purchase: when Forever blocked one this session, or for a reagent that
-- isn't a commodity (StartCommoditiesPurchase buys commodities only).
local function UsesSearch(line)
    return ns.Buy.Fallback() ~= nil or (not line.auction and not ns.Deposits.IsCommodity(line.itemID))
end

-- ---------------------------------------------------------------- what Buy does next

-- A recipe: at the AH its next AH line, at a merchant its next line this vendor sells (in whole stacks).
-- Returns where ("ah", "vendor" or nil), the line, and how many lines there are to buy there.
local function NextForRecipe(list)
    local line, n
    if ns.ahOpen then
        n = 0
        for _, e in ipairs(list.ah) do
            if not ns.Buy.Skipped(e.itemID) then
                n = n + 1
                line = line or e
            end
        end
        return "ah", line, n
    end
    if ns.Merchant.IsOpen() then
        n = 0
        for _, e in ipairs(list.vendor) do
            local slot = ns.Merchant.Find(e.itemID)
            local qty = slot and ns.Merchant.BuyQty(e.qty, slot.stack, slot.maxStack, slot.available) or 0
            if qty > 0 and not ns.Buy.Skipped(e.itemID) then
                n = n + 1
                line = line or { itemID = e.itemID, qty = qty, cost = slot.price * qty / slot.stack, slot = slot }
            end
        end
        return "vendor", line, n
    end
    return nil, nil, 0
end

-- A flip: a commodity's units still below the vendor's price (the flip's numbers, which a search renews), or
-- gear's cheapest auction under it (none until a search lists them). line.sell: what a vendor pays for one.
local function NextForFlip(r)
    local itemID = r.recipe.output
    local sell = ns.Flips.VendorSell(itemID) or (r.units > 0 and r.best / r.units) or 0
    local list = auctions[itemID]
    if list then
        for _, a in ipairs(list) do
            if a.buyout < sell * a.qty and not ns.Buy.Skipped(itemID) then
                return { itemID = itemID, qty = a.qty, cost = a.buyout, sell = sell, auction = a }
            end
        end
        return nil
    end
    if not ns.Deposits.IsCommodity(itemID) then return nil end
    if r.units > 0 and r.cogs < sell * r.units and not ns.Buy.Skipped(itemID) then
        return { itemID = itemID, qty = r.units, cost = r.cogs, sell = sell }
    end
    return nil
end

-- Whether Buy can act now, and why not.
local function CanBuy(r, list, where, line)
    if IsFlip(r) then
        if not ns.ahOpen then return false, L["Open the Auction House (talk to an auctioneer) to buy it."] end
        if Checking(r) then return false, L["Checking prices at the Auction House..."] end
        if not line then return false, L["Nothing is left below what a vendor pays."] end
        if ns.Buy.Fallback() then return true end
        return ns.Buy.CanStart(line.itemID, line.cost, true)
    end
    if not r.known then return false, L["You don't know this recipe yet."] end
    if where == nil then
        if #list.ah > 0 then return false, L["Open the Auction House (talk to an auctioneer) to buy what's missing."] end
        if #list.vendor > 0 then return false, L["Talk to a vendor that sells what's missing."] end
        return false, L["Nothing to buy."]
    end
    if where == "vendor" then
        if not line then return false, L["This vendor sells none of what's missing."] end
        return ns.Buy.CanVendor(line.itemID, line.cost)
    end
    if Checking(r) then return false, L["Checking prices at the Auction House..."] end
    if not line then
        if #list.ah > 0 then return false, L["Nothing more can be bought on the AH for now: hover it for why."] end
        return false, L["Nothing to buy on the Auction House."]
    end
    if UsesSearch(line) then return true end
    return ns.Buy.CanStart(line.itemID, line.cost)
end

-- ---------------------------------------------------------------- the status line

-- What's left to buy, summed up: "To buy: AH 1g 20s, vendor 40c, 1 short".
local function Summary(r, list)
    if Checking(r) then return GREY .. L["Checking prices at the Auction House..."] .. "|r" end
    if #list.ah + #list.vendor + #list.short == 0 then return GREEN .. L["Everything is in the tray."] .. "|r" end
    local parts = {}
    if #list.ah > 0 then parts[#parts + 1] = string.format(L["AH %s"], Money.Compact(list.ahCost)) end
    if #list.vendor > 0 then parts[#parts + 1] = string.format(L["vendor %s"], Money.Compact(list.vendorCost)) end
    if #list.short > 0 then parts[#parts + 1] = RED .. string.format(L["%d short"], #list.short) .. "|r" end
    return NORMAL_FONT_COLOR:WrapTextInColorCode(L["To buy:"]) .. " " .. table.concat(parts, ", ")
end

-- An open price: its total, the rise over the estimate in orange, red when it would lose money, and the last
-- seconds of a quote counted down.
local function QuoteText(p)
    local text = string.format(L["%d %s: %s"], p.qty, Name(p.itemID), Money.Compact(p.quoteTotal))
    local rise = p.quoteTotal - (p.estimate or p.quoteTotal)
    if rise >= 1 then text = text .. ORANGE .. " +" .. Money.Compact(rise) .. "|r" end
    local profit = ns.Buy.ProfitAt(p.profit, p.estimate or 0, p.quoteTotal)
    if profit and profit < 0 then text = RED .. text .. " " .. L["(a loss)"] .. "|r" end
    if p.left and p.left <= COUNTDOWN and (p.kind == "ah" or p.kind == "flip") then
        text = text .. GREY .. string.format(" %d s", p.left) .. "|r"
    end
    return Icon(p.itemID) .. text
end

local function StatusText(r, list, where, line, n)
    local state, p = ns.Buy.State()
    if p and not p.probe then
        if state == "quoting" then
            return Icon(p.itemID) .. string.format(L["%d %s: asking for the price..."], p.qty, Name(p.itemID))
        elseif state == "confirm" then
            return QuoteText(p)
        elseif state == "buying" then
            return Icon(p.itemID) .. string.format(L["Buying %d %s..."], p.qty, Name(p.itemID))
        end
    end
    if IsFlip(r) then
        if Checking(r) then return GREY .. L["Checking prices at the Auction House..."] .. "|r" end
        if not line then return GREY .. L["Nothing is left below what a vendor pays."] .. "|r" end
        return Icon(line.itemID) .. string.format(L["%d %s: %s, a vendor pays %s"], line.qty, Name(line.itemID),
            Money.Compact(line.cost), Money.Compact(line.sell * line.qty))
    end
    if line and not (where == "ah" and Checking(r)) then
        local text = Icon(line.itemID) .. string.format(L["%d %s: %s"], line.qty, Name(line.itemID), Money.Compact(line.cost))
        if where == "vendor" then text = text .. " " .. L["at this vendor"] end
        return text .. (n > 1 and (GREY .. string.format(L[" (+%d more)"], n - 1) .. "|r") or "")
    end
    return Summary(r, list)
end

function BuyBar.Refresh()
    if not bar then return end
    local r = current
    local shown = Applies(r)
    bar:SetShown(shown)
    ns.DetailPanel.SetBottomInset(shown and HEIGHT + 4 or 0)
    if not shown then return end
    local state = ns.Buy.State()
    local ready = state == "ready"
    local flip = IsFlip(r)
    local list = flip and nil or ns.Evaluator.ShoppingList(r)
    local where, line, n
    if flip then
        where, line, n = "ah", NextForFlip(r), 1
    else
        where, line, n = NextForRecipe(list)
    end
    bar.Crafts:SetShown(not flip)
    if not flip then
        silent = true
        bar.Crafts:SetMinMaxValues(1, math.max(MAX_CRAFTS, r.crafts))
        bar.Crafts:SetValue(r.crafts)
        silent = false
        bar.Crafts:SetEnabled(ready)
    end
    bar.Best:SetShown(not flip or not ready)
    bar.Best:SetText(ready and L["Best"] or L["Cancel"])
    bar.Best:SetEnabled(ready and (r.batch == nil or r.batch.size ~= nil) or state == "quoting" or state == "confirm")
    if state == "confirm" then
        bar.Buy:SetText(L["Confirm"])
        bar.Buy:SetEnabled(true)
    elseif ready then
        bar.Buy:SetText(line and where == "ah" and UsesSearch(line) and L["Search"] or L["Buy"])
        bar.Buy:SetEnabled((CanBuy(r, list, where, line)))
    else
        bar.Buy:SetText(L["Buy"])
        bar.Buy:SetEnabled(false)
    end
    bar.Status:SetText(StatusText(r, list, where, line, n))
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

-- An open price: what it costs against the estimate, the profit at it, and how long a quote holds.
local function QuoteTooltip(p)
    GameTooltip:AddDoubleLine(Line(p), Money.Format(p.quoteTotal), 1, 1, 1, 1, 1, 1)
    if p.estimate and p.kind ~= "auction" and p.kind ~= "vendor" then
        GameTooltip:AddDoubleLine(L["Expected"], Money.Format(p.estimate), 1, 0.82, 0, 1, 1, 1)
    end
    if p.sell then GameTooltip:AddDoubleLine(L["A vendor pays"], Money.Format(p.sell * p.qty), 1, 0.82, 0, 1, 1, 1) end
    local profit = ns.Buy.ProfitAt(p.profit, p.estimate or 0, p.quoteTotal)
    if profit then
        local loss = profit < 0
        GameTooltip:AddDoubleLine(L["Profit at this price"], Money.Format(math.abs(profit)) .. (loss and (" " .. L["loss"]) or ""),
            1, 0.82, 0, loss and 1 or 0.2, loss and 0.33 or 1, 0.2)
    end
    if p.kind == "ah" or p.kind == "flip" then
        GameTooltip:AddDoubleLine(L["The price holds"], string.format(L["%d s"], p.left or 0), 1, 0.82, 0, 1, 1, 1)
    end
    GameTooltip:AddLine(" ")
    if p.kind == "vendor" then
        GameTooltip:AddLine(L["It's 150g or more, so it waits for this click. It goes into your bags and your tray."], 0.6, 0.6, 0.6, true)
    elseif p.kind == "ah" then
        GameTooltip:AddLine(L["Confirm buys it. It comes by mail, and goes into your tray now."], 0.6, 0.6, 0.6, true)
    else
        GameTooltip:AddLine(L["Confirm buys it. It comes by mail: sell it to any vendor."], 0.6, 0.6, 0.6, true)
    end
end

local function FlipTooltip(r, line)
    if line then
        GameTooltip:AddDoubleLine(Line(line), Money.Format(line.cost), 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine(L["A vendor pays"], Money.Format(line.sell * line.qty), 1, 0.82, 0, 1, 1, 1)
        GameTooltip:AddDoubleLine(L["Profit"], Money.Format(line.sell * line.qty - line.cost), 1, 0.82, 0, 0.2, 1, 0.2)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(line.auction and L["One auction: Buy shows it, Confirm buys it. The next cheapest comes up after."]
            or L["Every unit still below what a vendor pays, in one quote: Buy asks for the price, Confirm buys it."], 1, 1, 1, true)
        GameTooltip:AddLine(L["It comes by mail: sell it to any vendor."], 0.6, 0.6, 0.6, true)
    end
    local problem = problems[r.recipe.output] or ns.Buy.Skipped(r.recipe.output)
    if problem then GameTooltip:AddLine(problem, 1, 0.33, 0.2, true) end
end

-- What Buy gets, and why it can't yet. Disabled, it still explains (motion scripts while disabled).
local function BuyTooltip(self)
    local r = current
    local state, p = ns.Buy.State()
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    if state == "confirm" and p then
        GameTooltip:SetText(L["Confirm the purchase"], 1, 1, 1)
        QuoteTooltip(p)
        GameTooltip:Show()
        return
    end
    if not Applies(r) then
        GameTooltip:SetText(L["Buy what's missing"], 1, 1, 1)
        GameTooltip:Show()
        return
    end
    local flip = IsFlip(r)
    local list = flip and nil or ns.Evaluator.ShoppingList(r)
    local where, line
    if flip then
        where, line = "ah", NextForFlip(r)
    else
        where, line = NextForRecipe(list)
    end
    GameTooltip:SetText(flip and L["Buy the flip"] or L["Buy what's missing"], 1, 1, 1)
    local ok, why = CanBuy(r, list, where, line)
    if not ok and state == "ready" then GameTooltip:AddLine(why, 1, 0.33, 0.2, true) end
    if flip then
        FlipTooltip(r, line)
        GameTooltip:Show()
        return
    end
    if line and where == "ah" and UsesSearch(line) then
        GameTooltip:AddLine(string.format(L["Puts %s in the Auction House's search box (on its Buy tab): buy it there."],
            Name(line.itemID)), 1, 1, 1, true)
        GameTooltip:AddLine(ns.Buy.Fallback() and string.format(L["Buying from here is off for this session: %s."], ns.Buy.Fallback())
            or L["It isn't a commodity, so it's bought one auction at a time."], 0.6, 0.6, 0.6, true)
    end
    if #list.ah > 0 then
        Section(L["Auction House"], list.ahCost)
        for _, e in ipairs(list.ah) do
            local skip = ns.Buy.Skipped(e.itemID) or problems[e.itemID]
            if skip then
                GameTooltip:AddDoubleLine(Line(e), skip, 1, 1, 1, 1, 0.33, 0.2)
            else
                GameTooltip:AddDoubleLine(Line(e), Money.Format(e.cost), 1, 1, 1, 1, 1, 1)
            end
        end
        local age = PriceAge(r, list)
        if age then GameTooltip:AddLine(age, 0.6, 0.6, 0.6, true) end
    end
    if #list.vendor > 0 then
        Section(L["Vendor"], list.vendorCost)
        for _, e in ipairs(list.vendor) do
            local slot = ns.Merchant.Find(e.itemID)
            local qty = slot and ns.Merchant.BuyQty(e.qty, slot.stack, slot.maxStack, slot.available)
            if slot and qty > e.qty then
                GameTooltip:AddDoubleLine(Line(e), string.format(L["%d here (stacks of %d)"], qty, slot.stack), 1, 1, 1, 1, 1, 1)
            else
                GameTooltip:AddDoubleLine(Line(e), Money.Format(e.cost), 1, 1, 1, 1, 1, 1)
            end
        end
        if not ns.Merchant.IsOpen() then GameTooltip:AddLine(L["Buy these at a vendor that sells them."], 0.6, 0.6, 0.6, true) end
    end
    if #list.short > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(L["Can't be bought"], 1, 0.33, 0.2)
        for _, e in ipairs(list.short) do
            local reason = e.available and string.format(L["only %d listed"], e.available) or problems[e.itemID] or L["no price"]
            GameTooltip:AddDoubleLine(Line(e), reason, 1, 1, 1, 1, 0.33, 0.2)
        end
    end
    if #list.tray > 0 then
        Section(L["From your tray"])
        for _, e in ipairs(list.tray) do
            local mail = ns.Buy.InMail(e.itemID)
            if mail > 0 then
                GameTooltip:AddDoubleLine(Line(e), string.format(L["%d in the mailbox"], mail), 1, 1, 1, 0.6, 0.6, 0.6)
            else
                GameTooltip:AddLine(Line(e), 1, 1, 1)
            end
        end
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L["At the AH, Buy asks for the price and Confirm buys it; at a vendor, Buy buys it. Bags and bank don't count in this tab: put what you have in the tray."],
        0.6, 0.6, 0.6, true)
    GameTooltip:Show()
end

local function BestTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    if ns.Buy.IsBusy() then
        GameTooltip:SetText(L["Cancel"], 1, 1, 1)
        GameTooltip:AddLine(L["Drops the price shown: nothing is bought."], nil, nil, nil, true)
        GameTooltip:Show()
        return
    end
    GameTooltip:SetText(L["Best"], 1, 1, 1)
    GameTooltip:AddLine(L["Sets the crafts to the best batch (the reagents and the market), within your gold."], nil, nil, nil, true)
    local r = current
    if IsRecipe(r) then
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

-- ---------------------------------------------------------------- clicks

-- Best, or Cancel while a price is open.
local function OnBest()
    if ns.Buy.IsBusy() then
        ns.Buy.Cancel()
        return
    end
    local r = current
    if not IsRecipe(r) then return end
    local n = ns.Evaluator.AffordableBatch(r, GetMoney())
    if n then ns.ResultsList.SetCrafts(r.recipe.recipeID, n) end
end

-- Buy starts the next line's purchase, Confirm finishes it; both inside the click (Pricing/Buy.lua).
local function OnBuy()
    local state = ns.Buy.State()
    if state == "confirm" then
        ns.Buy.Confirm()
        return
    end
    local r = current
    if state ~= "ready" or not Applies(r) then return end
    if IsFlip(r) then
        local line = NextForFlip(r)
        if not line then return end
        if ns.Buy.Fallback() then
            if not ns.Buy.SearchInAH(line.itemID) then ns.Print(L["Switch the Auction House to its Buy tab, then try again."]) end
        elseif line.auction then
            ns.Buy.StartAuction(line.itemID, line.auction, { sell = line.sell, profit = line.sell * line.qty - line.cost })
        else
            local _, age = ns.PriceDB.Get(line.itemID)
            ns.Buy.Start(line.itemID, line.qty, { estimate = line.cost, fresh = age ~= nil and age < FRESH_QUOTE, sell = line.sell,
                                                  profit = line.sell * line.qty - line.cost })
        end
        return
    end
    local where, line = NextForRecipe(ns.Evaluator.ShoppingList(r))
    if not line then return end
    if where == "vendor" then
        ns.Buy.StartVendor(line.itemID, line.qty, line.slot, { recipeID = r.recipe.recipeID, profit = r.profit })
        return
    end
    if UsesSearch(line) then
        if not ns.Buy.SearchInAH(line.itemID) then ns.Print(L["Switch the Auction House to its Buy tab, then try again."]) end
        return
    end
    local _, age = ns.PriceDB.Get(line.itemID)
    ns.Buy.Start(line.itemID, line.qty, { estimate = line.cost, fresh = age ~= nil and age < FRESH_QUOTE,
                                          recipeID = r.recipe.recipeID, profit = r.profit })
end

-- ---------------------------------------------------------------- build

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

    bar.Buy = UI.Button(bar, L["Buy"], 80, OnBuy)
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
        if silent or not IsRecipe(current) or value < 1 then return end
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
    for id, v in pairs(pending) do
        if v == "eval" then pending[id] = nil end   -- this result is evaluated at the searched prices
    end
    if Applies(result) then CheckPrices(result) end
    BuyBar.Refresh()
end)

-- Opening the AH, or the window at the AH, checks the shown recipe's or flip's prices.
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
    wipe(auctions)
    BuyBar.Refresh()
end)

-- Any search of a gear item brings its auctions (the bar's own, and the one after each purchase).
ns.On("SEARCH_DONE", function(itemID, result, _, empty)
    if result and result.auctions then
        auctions[itemID] = result.auctions
    elseif empty then
        auctions[itemID] = nil
    end
    BuyBar.Refresh()
end)

-- The purchase moved on, the throttle is ready, a vendor opened, closed or listed its goods.
for _, message in ipairs({ "BUY_CHANGED", "AH_THROTTLE_READY", "MERCHANT_OPEN", "MERCHANT_ITEMS", "MERCHANT_CLOSED" }) do
    ns.On(message, function() BuyBar.Refresh() end)
end

function events:PLAYER_MONEY()
    BuyBar.Refresh()
end
ns.eventFrame:RegisterEvent("PLAYER_MONEY")
