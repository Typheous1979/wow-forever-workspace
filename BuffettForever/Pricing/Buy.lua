local addonName, ns = ...

-- Buying at the Auction House. For now a probe only (/bf buytest, not in the help), to learn before the
-- Buy button is built whether Forever lets an addon buy a commodity the way Blizzard's own Buy and Buy Now
-- buttons do, and where the purchase lands (the bags or the mailbox):
--   /bf buytest <itemID> <quantity>   C_AuctionHouse.StartCommoditiesPurchase [HasRestrictions]: a quote
--   /bf buytest confirm               ConfirmCommoditiesPurchase at that quote
--   /bf buytest cancel                CancelCommoditiesPurchase
-- Each call runs straight from the typed command (a key press, as Blizzard's buttons run from a click),
-- never from a timer. Every step and event, with its time since the start, goes to diag.purchases (the last
-- 20), and so do the bag count and your gold 2 seconds after a purchase. The quote and purchase events
-- don't name the item, so they're read only while a probe is open; Blizzard's own buy dialog shares the one
-- quote, so the probe won't start while it's open.

local L = ns.L
local Money = ns.Money
local Buy = {}
ns.Buy = Buy
local events = ns.events

local KEEP = 20            -- purchases kept in diag.purchases
local DELIVERY_CHECK = 2   -- seconds after a purchase to count the bags
local ANSWER_TIMEOUT = 10  -- seconds to wait for a quote or a purchase's outcome

local probe, timer   -- the open probe and its no-answer timer

local function Step(text)
    if not probe then return end
    probe.steps[#probe.steps + 1] = string.format("%.1fs %s", (debugprofilestop() - probe.started) / 1000, text)
end

local function StopTimer()
    if timer then
        timer:Cancel()
        timer = nil
    end
end

-- Close the probe and keep it in diag.purchases; returns the kept record.
local function Finish(outcome)
    local rec = probe
    if not rec then return nil end
    StopTimer()
    Step("outcome " .. outcome)
    rec.outcome, rec.started, probe = outcome, nil, nil
    if ns.db and not ns.readOnlyDB then
        local list = ns.db.diag.purchases or {}
        ns.db.diag.purchases = list
        table.insert(list, 1, rec)
        while #list > KEEP do table.remove(list) end
    end
    return rec
end

local function WaitForAnswer(what)
    StopTimer()
    timer = C_Timer.NewTimer(ANSWER_TIMEOUT, function()
        timer = nil
        if not probe then return end
        Step("no answer to " .. what)
        ns.Print(string.format(L["Purchase test: no answer to the %s within %d seconds (logged)."], L[what], ANSWER_TIMEOUT))
        Finish("no answer to " .. what)
    end)
end

local function BlizzardDialogOpen()
    local dialog = AuctionHouseFrame and AuctionHouseFrame.BuyDialog
    return dialog ~= nil and dialog:IsShown()
end

local function Start(itemID, qty)
    if not ns.ahOpen then
        ns.Print(L["Purchase test: open the Auction House first."])
        return
    end
    if probe then
        ns.Print(L["Purchase test: one is already open. /bf buytest cancel drops it."])
        return
    end
    if BlizzardDialogOpen() then
        ns.Print(L["Purchase test: close Blizzard's buy window first (the Auction House has one quote at a time)."])
        return
    end
    probe = { t = GetServerTime(), build = select(2, GetBuildInfo()), itemID = itemID, qty = qty, steps = {},
              started = debugprofilestop(), bagsBefore = C_Item.GetItemCount(itemID),
              withBankBefore = C_Item.GetItemCount(itemID, true), moneyBefore = GetMoney() }
    local ok, err = pcall(C_AuctionHouse.StartCommoditiesPurchase, itemID, qty)
    Step(ok and "StartCommoditiesPurchase called" or ("StartCommoditiesPurchase error: " .. tostring(err)))
    if not ok then
        ns.Print(L["Purchase test: the call failed (logged)."])
        Finish("start error")
        return
    end
    ns.Print(string.format(L["Purchase test: asked for a quote for %d %s."], qty, ns.Items.Link(itemID)))
    WaitForAnswer("quote")
end

local function Confirm()
    if not probe or not probe.quoteTotal then
        ns.Print(L["Purchase test: no quote yet. /bf buytest <itemID> <quantity> asks for one."])
        return
    end
    if probe.quoteTotal > GetMoney() then
        ns.Print(L["Purchase test: you don't have enough gold for that quote."])
        return
    end
    probe.quoteLeftAtConfirm = C_AuctionHouse.GetQuoteDurationRemaining()
    local ok, err = pcall(C_AuctionHouse.ConfirmCommoditiesPurchase, probe.itemID, probe.qty)
    Step(ok and "ConfirmCommoditiesPurchase called" or ("ConfirmCommoditiesPurchase error: " .. tostring(err)))
    if not ok then
        ns.Print(L["Purchase test: the call failed (logged)."])
        Finish("confirm error")
        return
    end
    WaitForAnswer("purchase")
end

local function Cancel(why)
    if not probe then return end
    pcall(C_AuctionHouse.CancelCommoditiesPurchase)
    Step("CancelCommoditiesPurchase called")
    Finish(why or "cancelled")
    ns.Print(L["Purchase test: cancelled."])
end

-- /bf buytest <itemID> <quantity> | confirm | cancel
function Buy.Probe(msg)
    local arg1, arg2 = string.match(msg or "", "^%s*%S+%s*(%S*)%s*(%S*)")
    arg1 = string.lower(arg1 or "")
    if arg1 == "confirm" then
        Confirm()
    elseif arg1 == "cancel" then
        Cancel()
    else
        local itemID, qty = tonumber(arg1), tonumber(arg2) or 1
        if not itemID or qty < 1 then
            ns.Print(L["Usage: /bf buytest <itemID> <quantity>, then /bf buytest confirm or cancel"])
            return
        end
        Start(itemID, math.floor(qty))
    end
end

-- ---------------------------------------------------------------- events

function events:COMMODITY_PRICE_UPDATED(unitPrice, totalPrice)
    if not probe then return end
    StopTimer()
    probe.quoteUnit, probe.quoteTotal = unitPrice, totalPrice
    probe.quoteSeconds = C_AuctionHouse.GetQuoteDurationRemaining()
    Step(string.format("quote %s each, %s in all, %s s left", tostring(unitPrice), tostring(totalPrice),
        tostring(probe.quoteSeconds)))
    ns.Print(string.format(L["Purchase test: %d %s for %s (%s each), good for %s s. /bf buytest confirm buys it; /bf buytest cancel drops it."],
        probe.qty, ns.Items.Link(probe.itemID), Money.Format(totalPrice), Money.Format(unitPrice), tostring(probe.quoteSeconds)))
end

function events:COMMODITY_PRICE_UNAVAILABLE()
    if not probe then return end
    Step("COMMODITY_PRICE_UNAVAILABLE")
    ns.Print(L["Purchase test: the Auction House has no price for that quantity (logged)."])
    Finish("price unavailable")
end

function events:COMMODITY_PURCHASED(itemID, quantity)
    if not probe then return end
    probe.purchased = quantity
    Step(string.format("COMMODITY_PURCHASED %s x%s", tostring(itemID), tostring(quantity)))
end

function events:COMMODITY_PURCHASE_SUCCEEDED()
    if not probe then return end
    Step("COMMODITY_PURCHASE_SUCCEEDED")
    local rec = Finish("bought")
    C_Timer.After(DELIVERY_CHECK, function()
        rec.bagsAfter = C_Item.GetItemCount(rec.itemID)
        rec.withBankAfter = C_Item.GetItemCount(rec.itemID, true)
        rec.moneyAfter = GetMoney()
        rec.delivered = rec.bagsAfter > rec.bagsBefore and "bags" or "not in the bags (the mailbox?)"
        ns.Print(string.format(L["Purchase test: bought. Bags %d -> %d, gold spent %s: %s."], rec.bagsBefore, rec.bagsAfter,
            Money.Format(rec.moneyBefore - rec.moneyAfter), rec.delivered))
    end)
end

function events:COMMODITY_PURCHASE_FAILED()
    if not probe then return end
    Step("COMMODITY_PURCHASE_FAILED")
    ns.Print(L["Purchase test: the purchase failed (logged)."])
    Finish("failed")
end

function events:AUCTION_HOUSE_SHOW_ERROR(err)
    if not probe then return end
    Step("AUCTION_HOUSE_SHOW_ERROR " .. tostring(err))
end

-- Blizzard blocked a call: the payload names the addon and the function.
local function Blocked(event, who, fn)
    if not probe and who ~= addonName then return end
    if probe then
        Step(string.format("%s %s %s", event, tostring(who), tostring(fn)))
    elseif ns.db and not ns.readOnlyDB then
        ns.db.diag.blocked = { t = GetServerTime(), event = event, fn = tostring(fn) }
    end
end

function events:ADDON_ACTION_BLOCKED(who, fn) Blocked("ADDON_ACTION_BLOCKED", who, fn) end
function events:ADDON_ACTION_FORBIDDEN(who, fn) Blocked("ADDON_ACTION_FORBIDDEN", who, fn) end

ns.On("AH_CLOSED", function()
    if probe then Cancel("the Auction House closed") end
end)

-- /bf diag: the last purchases, newest first.
function Buy.PrintDiag()
    for i, rec in ipairs(ns.db and ns.db.diag.purchases or {}) do
        if i > 3 then break end
        ns.Print(string.format("purchase %d x%d: %s; bags %s -> %s (%s); %s", rec.itemID, rec.qty, tostring(rec.outcome),
            tostring(rec.bagsBefore), tostring(rec.bagsAfter), tostring(rec.delivered), table.concat(rec.steps or {}, ", ")))
    end
end

for _, event in ipairs({ "COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE", "COMMODITY_PURCHASED",
    "COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED", "AUCTION_HOUSE_SHOW_ERROR", "ADDON_ACTION_BLOCKED",
    "ADDON_ACTION_FORBIDDEN" }) do
    ns.eventFrame:RegisterEvent(event)
end
