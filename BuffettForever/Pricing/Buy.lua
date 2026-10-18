local addonName, ns = ...

-- Buying at the Auction House (auction-house.md "Buying"), one commodity at a time, two clicks each, the
-- price shown before the second (Justin, 2026-10-17: "Live price, then confirm"):
--   Buy      -> StartCommoditiesPurchase(itemID, qty)   -> COMMODITY_PRICE_UPDATED(unit, total): a quote, 30 s
--   Confirm  -> ConfirmCommoditiesPurchase(itemID, qty) -> COMMODITY_PURCHASE_SUCCEEDED or _FAILED
-- States: ready, quoting, confirm, buying. Each call runs inside the player's click (or a typed /bf buytest),
-- never from a timer, a queue or an event. The events don't name the item, so they count only in this
-- module's own states. Blizzard's buy dialog shares the one quote: nothing starts while it's open, and an
-- open quote gives way to it. A quote more than 5% over a fresh search's price is refused, as Blizzard's
-- dialog does; over an older price, the rise is shown.
-- What's bought arrives by mail [F-132]. Tray.Credit adds it to the tray, so the Profession profits plan
-- never offers it twice, and charDB.bought remembers it until your bags and bank hold it (Buy.InMail).
-- If Forever blocks a purchase, or nothing answers twice, buying moves to Blizzard's search box for the
-- session (Buy.Fallback, Buy.SearchInAH). Every step goes to diag.purchases (the last 20).
-- /bf buytest <itemID> <quantity> | confirm | cancel probes a purchase with no recipe (nothing credited).
-- BUY_CHANGED tells the Buy bar.

local L = ns.L
local Money = ns.Money
local Buy = {}
ns.Buy = Buy
local events = ns.events

local KEEP = 20             -- purchases kept in diag.purchases
local DELIVERY_CHECK = 2    -- seconds after a purchase to count the bags
local ANSWER_TIMEOUT = 10   -- seconds to wait for a quote or a purchase's outcome
local TICK = 0.2            -- seconds between quote checks (time left, Blizzard's dialog)
local MAX_RISE = 1.05       -- Blizzard's MAXIMUM_PREVIEW_PRICE_DIFFERENTIAL
local MAIL_DAYS = 30        -- AH mail lasts 30 days [F-130]
local NO_ANSWERS = 2        -- quotes in a row with no answer before falling back to the search box

local state = "ready"
local purchase           -- the open purchase
local timer, ticker
local fallback           -- why buying moved to Blizzard's search box this session
local noAnswers = 0
local inCombat = false   -- from PLAYER_REGEN_DISABLED until COMBAT_ENDED (InCombatLockdown lags the event)
local skipped = {}       -- [itemID] = why its last quote failed, this visit to the AH

local function Changed()
    ns.Fire("BUY_CHANGED", state)
end

local function Step(text)
    if not purchase then return end
    purchase.steps[#purchase.steps + 1] = string.format("%.1fs %s", (debugprofilestop() - purchase.started) / 1000, text)
end

local function StopTimers()
    if timer then
        timer:Cancel()
        timer = nil
    end
    if ticker then
        ticker:Cancel()
        ticker = nil
    end
end

-- Close the purchase, keep it in diag.purchases, and go back to ready; returns the kept record.
local function Finish(outcome)
    local rec = purchase
    if not rec then return nil end
    StopTimers()
    Step("outcome " .. outcome)
    rec.outcome, rec.started, purchase, state = outcome, nil, nil, "ready"
    if ns.db and not ns.readOnlyDB then
        local list = ns.db.diag.purchases or {}
        ns.db.diag.purchases = list
        table.insert(list, 1, rec)
        while #list > KEEP do table.remove(list) end
    end
    Changed()
    ns.Search.Pump()   -- searches wait while a purchase is open
    return rec
end

local function BlizzardDialogOpen()
    local dialog = AuctionHouseFrame and AuctionHouseFrame.BuyDialog
    return dialog ~= nil and dialog:IsShown()
end

local function Link(itemID)
    return ns.Items.Link(itemID)
end

-- ---------------------------------------------------------------- pure helpers (the self-test runs them)

-- A quote against the price shown: "ok", "higher" (shown as a rise), or "refuse" when it's more than 5% over
-- a fresh search's price (Blizzard's buy dialog refuses those too). Totals in copper.
function Buy.QuoteCheck(estimate, quote, fresh)
    if quote > estimate * MAX_RISE + 0.5 then return fresh and "refuse" or "higher" end
    if quote > estimate + 0.5 then return "higher" end
    return "ok"
end

-- The recipe's profit when one line costs quote instead of its estimate (nil when the profit is unknown).
function Buy.ProfitAt(profit, estimate, quote)
    if not profit then return nil end
    return profit + estimate - quote
end

-- Units of a purchase not in your bags or bank yet: entry = { q bought, base = the count then }.
function Buy.Pending(entry, count)
    return math.max(0, math.min(entry.q, entry.base + entry.q - count))
end

-- ---------------------------------------------------------------- the mail ledger

local function Ledger()
    return ns.charDB and ns.charDB.bought
end

-- Units of itemID bought and still on their way (in the mailbox).
function Buy.InMail(itemID)
    local entry = Ledger() and Ledger()[itemID]
    if not entry then return 0 end
    return Buy.Pending(entry, C_Item.GetItemCount(itemID, true))
end

local function Remember(itemID, n)
    local ledger = Ledger()
    if not ledger then return end
    local count, entry = C_Item.GetItemCount(itemID, true), ledger[itemID]
    if entry and Buy.Pending(entry, count) > 0 then
        entry.q, entry.t = entry.q + n, GetServerTime()
    else
        ledger[itemID] = { q = n, base = count, t = GetServerTime() }
    end
end

-- What has arrived leaves the ledger; so does anything older than the mail it came in.
ns.On("BAGS_CHANGED", function()
    local ledger = Ledger()
    if not ledger then return end
    local now = GetServerTime()
    for itemID, entry in pairs(ledger) do
        if Buy.Pending(entry, C_Item.GetItemCount(itemID, true)) == 0 or now - entry.t > MAIL_DAYS * 86400 then
            ledger[itemID] = nil
        end
    end
end)

-- ---------------------------------------------------------------- the purchase

function Buy.State()
    return state, purchase
end

function Buy.IsBusy()
    return state ~= "ready"
end

function Buy.Skipped(itemID)
    return skipped[itemID]
end

function Buy.Fallback()
    return fallback
end

-- Whether a quote can start now, and why not: the shared checks for the Buy button and /bf buytest.
-- cost: the estimate (0 when unknown); probe: no recipe, so no tray room needed.
function Buy.CanStart(itemID, cost, probe)
    if not ns.ahOpen then return false, L["Open the Auction House (talk to an auctioneer) to buy what's missing."] end
    if inCombat or InCombatLockdown() then return false, L["Not in combat."] end
    if state ~= "ready" then return false, L["A purchase is already open."] end
    if BlizzardDialogOpen() then return false, L["Close Blizzard's buy window first: the Auction House quotes one price at a time."] end
    if ns.Scanner.IsBusy() then return false, L["A full scan is running."] end
    if ns.Search.IsBusy() then return false, L["Checking prices at the Auction House..."] end
    if not C_AuctionHouse.IsThrottledMessageSystemReady() then return false, L["The Auction House is busy: a moment."] end
    if cost > GetMoney() then
        return false, string.format(L["Not enough gold: %s, and you have %s."], Money.Format(cost), Money.Format(GetMoney()))
    end
    if not probe and not ns.Tray.HasRoom(itemID) then return false, L["The tray is full: make room for what you buy."] end
    return true
end

local function WaitForAnswer(what)
    if timer then timer:Cancel() end
    timer = C_Timer.NewTimer(ANSWER_TIMEOUT, function()
        timer = nil
        if not purchase then return end
        Step("no answer to the " .. what)
        local rec = purchase
        if what == "quote" then
            pcall(C_AuctionHouse.CancelCommoditiesPurchase)
            noAnswers = noAnswers + 1
            if noAnswers >= NO_ANSWERS and not fallback then fallback = L["the Auction House didn't answer twice"] end
            ns.Print(string.format(L["No price came for %s: try again in a moment."], Link(rec.itemID)))
            Finish("no answer to the quote")
        else
            ns.Print(string.format(L["No answer to the purchase of %d %s: check your mailbox before buying it again."],
                rec.qty, Link(rec.itemID)))
            Finish("outcome unknown")
        end
    end)
end

-- opts: { estimate (copper for qty), fresh (the estimate is from a search under 2 minutes old), recipeID,
-- profit (the recipe's at the estimate), probe }. Runs inside the click. Returns true when a quote was asked.
function Buy.Start(itemID, qty, opts)
    local ok, why = Buy.CanStart(itemID, opts.estimate or 0, opts.probe)
    if not ok then
        ns.Print(why)
        return false
    end
    purchase = { t = GetServerTime(), build = select(2, GetBuildInfo()), itemID = itemID, qty = qty,
                 estimate = opts.estimate, fresh = opts.fresh, recipeID = opts.recipeID, profit = opts.profit,
                 probe = opts.probe, steps = {}, started = debugprofilestop(), bagsBefore = C_Item.GetItemCount(itemID),
                 withBankBefore = C_Item.GetItemCount(itemID, true), moneyBefore = GetMoney() }
    state = "quoting"   -- before the call, so no answer can come in while still "ready"
    local called, err = pcall(C_AuctionHouse.StartCommoditiesPurchase, itemID, qty)
    Step(called and "StartCommoditiesPurchase called" or ("StartCommoditiesPurchase error: " .. tostring(err)))
    if not called then
        ns.Print(L["The Auction House wouldn't quote it (logged)."])
        Finish("start error")
        return false
    end
    WaitForAnswer("quote")
    Changed()
    return true
end

-- Runs inside the Confirm click.
function Buy.Confirm()
    if state ~= "confirm" or not purchase then return end
    if C_AuctionHouse.GetQuoteDurationRemaining() <= 0 then
        Buy.Cancel(L["the price ran out"])
        return
    end
    if purchase.quoteTotal > GetMoney() then
        ns.Print(string.format(L["Not enough gold: %s, and you have %s."], Money.Format(purchase.quoteTotal), Money.Format(GetMoney())))
        return
    end
    purchase.quoteLeftAtConfirm = C_AuctionHouse.GetQuoteDurationRemaining()
    local called, err = pcall(C_AuctionHouse.ConfirmCommoditiesPurchase, purchase.itemID, purchase.qty)
    Step(called and "ConfirmCommoditiesPurchase called" or ("ConfirmCommoditiesPurchase error: " .. tostring(err)))
    if not called then
        ns.Print(L["The purchase didn't go through (logged)."])
        Finish("confirm error")
        return
    end
    if ticker then
        ticker:Cancel()
        ticker = nil
    end
    state = "buying"
    WaitForAnswer("purchase")
    Changed()
end

-- Drop an open price (quoting or confirm) and log the outcome. A purchase on its way can't be called back.
local function Drop(outcome)
    if state == "ready" or state == "buying" then return end
    pcall(C_AuctionHouse.CancelCommoditiesPurchase)
    Step("CancelCommoditiesPurchase called")
    Finish(outcome)
end

-- why: said in chat and logged (nil: the player's own Cancel).
function Buy.Cancel(why)
    if state == "ready" or state == "buying" then return end
    if why then ns.Print(string.format(L["Purchase cancelled: %s."], why)) end
    Drop(why or "cancelled")
end

-- The quote is Blizzard's now (its buy dialog opened): stop reading the events, cancel nothing.
local function GiveWay()
    Step("Blizzard's buy dialog opened")
    Finish("Blizzard's buy dialog took over")
end

local function Tick()
    if state ~= "confirm" or not purchase then return end
    if BlizzardDialogOpen() then
        GiveWay()
        return
    end
    local left = C_AuctionHouse.GetQuoteDurationRemaining()
    if left <= 0 then
        Buy.Cancel(L["the price ran out"])
    elseif left ~= purchase.left then
        purchase.left = left
        Changed()
    end
end

-- Put the item's name in Blizzard's search box (its Buy tab), where the player buys it. Returns false
-- when the AH frame isn't on a Buy tab or the name isn't loaded.
function Buy.SearchInAH(itemID)
    local name = C_Item.GetItemNameByID(itemID)
    if not name or not AuctionHouseFrame or not AuctionHouseFrame.SetSearchText then return false end
    return AuctionHouseFrame:SetSearchText(name) == true
end

-- ---------------------------------------------------------------- events

function events:COMMODITY_PRICE_UPDATED(unitPrice, totalPrice)
    if (state ~= "quoting" and state ~= "confirm") or not purchase then return end
    if BlizzardDialogOpen() then
        GiveWay()
        return
    end
    if timer then
        timer:Cancel()
        timer = nil
    end
    noAnswers = 0
    purchase.quoteUnit, purchase.quoteTotal = unitPrice, totalPrice
    purchase.quoteSeconds = C_AuctionHouse.GetQuoteDurationRemaining()
    Step(string.format("quote %s each, %s in all, %s s left", tostring(unitPrice), tostring(totalPrice),
        tostring(purchase.quoteSeconds)))
    if purchase.probe then
        ns.Print(string.format(L["Purchase test: %d %s for %s (%s each), good for %s s. /bf buytest confirm buys it; /bf buytest cancel drops it."],
            purchase.qty, Link(purchase.itemID), Money.Format(totalPrice), Money.Format(unitPrice), tostring(purchase.quoteSeconds)))
    elseif Buy.QuoteCheck(purchase.estimate or 0, totalPrice, purchase.fresh) == "refuse" then
        local itemID = purchase.itemID
        skipped[itemID] = L["the price rose more than 5% since the search"]
        Buy.Cancel(string.format(L["%s costs more than 5%% above the price just seen; looking again"], Link(itemID)))
        ns.Search.Request(itemID)   -- a fresh price, then the plan offers it again
        return
    end
    state = "confirm"
    purchase.left = purchase.quoteSeconds
    if not ticker then ticker = C_Timer.NewTicker(TICK, Tick) end
    Changed()
end

function events:COMMODITY_PRICE_UNAVAILABLE()
    if (state ~= "quoting" and state ~= "confirm") or not purchase then return end
    Step("COMMODITY_PRICE_UNAVAILABLE")
    noAnswers = 0
    local rec = purchase
    if not rec.probe then
        skipped[rec.itemID] = string.format(L["%d aren't listed now"], rec.qty)
        ns.Search.Request(rec.itemID)   -- what is listed, for the next plan
    end
    ns.Print(string.format(L["The Auction House has no price for %d %s now."], rec.qty, Link(rec.itemID)))
    Drop("price unavailable")
end

function events:COMMODITY_PURCHASED(itemID, quantity)
    if state ~= "buying" or not purchase then return end
    Step(string.format("COMMODITY_PURCHASED %s x%s", tostring(itemID), tostring(quantity)))
    if itemID == purchase.itemID then purchase.purchased = quantity end
end

function events:COMMODITY_PURCHASE_SUCCEEDED()
    if state ~= "buying" or not purchase then return end
    Step("COMMODITY_PURCHASE_SUCCEEDED")
    local rec = purchase
    local n = rec.purchased or rec.qty
    if not rec.probe then
        rec.credited = ns.Tray.Credit(rec.itemID, n) ~= nil
        Remember(rec.itemID, n)
    end
    Finish("bought")
    ns.Print(string.format(L["Bought %d %s for %s: it comes by mail."], n, Link(rec.itemID), Money.Format(rec.quoteTotal or 0)))
    C_Timer.After(DELIVERY_CHECK, function()
        rec.bagsAfter = C_Item.GetItemCount(rec.itemID)
        rec.withBankAfter = C_Item.GetItemCount(rec.itemID, true)
        rec.moneyAfter = GetMoney()
        rec.delivered = rec.bagsAfter > rec.bagsBefore and "bags" or "not in the bags (the mailbox?)"
    end)
    if not rec.probe then ns.ResultsList.Update() end   -- the plan's next line now, not after the tray's debounce
end

function events:COMMODITY_PURCHASE_FAILED()
    if state ~= "buying" or not purchase then return end
    Step("COMMODITY_PURCHASE_FAILED")
    ns.Print(string.format(L["The purchase of %s failed: nothing was bought."], Link(purchase.itemID)))
    Finish("failed")
end

function events:AUCTION_HOUSE_SHOW_ERROR(err)
    if state == "ready" or not purchase then return end
    Step("AUCTION_HOUSE_SHOW_ERROR " .. tostring(err))
    if state == "buying" then
        ns.Print(string.format(L["The purchase of %s failed: nothing was bought."], Link(purchase.itemID)))
        Finish("error " .. tostring(err))
    else
        Buy.Cancel(L["the Auction House reported an error"])
    end
end

-- Blizzard blocked a call: the payload names the addon and the function. During a purchase, buying moves to
-- the search box for the session.
local function Blocked(event, who, fn)
    if who ~= addonName then return end
    if ns.db and not ns.readOnlyDB then ns.db.diag.blocked = { t = GetServerTime(), event = event, fn = tostring(fn) } end
    if not purchase then return end
    fallback = string.format(L["Forever blocked %s"], tostring(fn))
    Step(string.format("%s %s", event, tostring(fn)))
    Finish("blocked")
end

function events:ADDON_ACTION_BLOCKED(who, fn) Blocked("ADDON_ACTION_BLOCKED", who, fn) end
function events:ADDON_ACTION_FORBIDDEN(who, fn) Blocked("ADDON_ACTION_FORBIDDEN", who, fn) end

function events:PLAYER_REGEN_DISABLED()
    inCombat = true
    Buy.Cancel(L["combat"])
    Changed()
end

ns.On("COMBAT_ENDED", function()
    inCombat = false
    Changed()
end)

ns.On("AH_CLOSED", function()
    Buy.Cancel(L["the Auction House closed"])
    if state == "buying" then Finish("the Auction House closed while buying: check your mailbox") end
    wipe(skipped)
end)

-- Another recipe or view while a quote is open: the quote was for the one before.
ns.On("DETAILS_SHOWN", function(_, changed)
    if changed and purchase and not purchase.probe then Buy.Cancel(L["another recipe was picked"]) end
end)

-- A fresh price lets a skipped line be tried again.
ns.On("PRICES_CHANGED", function(itemID)
    if itemID then skipped[itemID] = nil end
end)

-- ---------------------------------------------------------------- /bf buytest

-- /bf buytest <itemID> <quantity> | confirm | cancel (typed, so each call is still the player's own key press)
function Buy.Probe(msg)
    local arg1, arg2 = string.match(msg or "", "^%s*%S+%s*(%S*)%s*(%S*)")
    arg1 = string.lower(arg1 or "")
    if arg1 == "confirm" then
        Buy.Confirm()
    elseif arg1 == "cancel" then
        Buy.Cancel()
    else
        local itemID, qty = tonumber(arg1), tonumber(arg2) or 1
        if not itemID or qty < 1 then
            ns.Print(L["Usage: /bf buytest <itemID> <quantity>, then /bf buytest confirm or cancel"])
            return
        end
        if Buy.Start(itemID, math.floor(qty), { probe = true }) then
            ns.Print(string.format(L["Purchase test: asked for a quote for %d %s."], math.floor(qty), Link(itemID)))
        end
    end
end

-- /bf diag: the last purchases, newest first.
function Buy.PrintDiag()
    for i, rec in ipairs(ns.db and ns.db.diag.purchases or {}) do
        if i > 3 then break end
        ns.Print(string.format("purchase %d x%d%s: %s; quote %s (estimate %s); bags %s -> %s (%s); %s", rec.itemID, rec.qty,
            rec.probe and " (test)" or "", tostring(rec.outcome), tostring(rec.quoteTotal), tostring(rec.estimate),
            tostring(rec.bagsBefore), tostring(rec.bagsAfter), tostring(rec.delivered), table.concat(rec.steps or {}, ", ")))
    end
    if fallback then ns.Print("purchases fall back to the search box: " .. fallback) end
end

-- ---------------------------------------------------------------- self-test

function Buy.SelfTest(report)
    local passed, failed = 0, 0
    local function check(name, ok, detail)
        if ok then passed = passed + 1 else failed = failed + 1 end
        report(name, ok, detail)
    end
    local Q = Buy.QuoteCheck
    check("QUOTE-CHECK", Q(1000, 1000, true) == "ok" and Q(1000, 990, true) == "ok" and Q(1000, 1040, true) == "higher"
        and Q(1000, 1060, true) == "refuse" and Q(1000, 1060, false) == "higher" and Buy.ProfitAt(500, 1000, 1060) == 440
        and Buy.ProfitAt(nil, 1000, 1060) == nil,
        "the same or less: ok; 4% more: shown; 6% more: refused after a fresh search, shown after an old scan; profit follows")
    local entries = { { itemID = 1, qty = 3 } }
    local same = ns.Tray.CreditEntries(entries, 1, 12)
    local new = ns.Tray.CreditEntries(entries, 2, 5)
    local full = {}
    for i = 1, ns.Tray.SIZE do full[i] = { itemID = 100 + i, qty = 1 } end
    check("TRAY-CREDIT", same == 1 and entries[1].qty == 15 and new == 2 and entries[2].qty == 5
        and ns.Tray.CreditEntries(full, 999, 1) == nil and ns.Tray.CreditEntries(full, 101, 1) == 1 and full[1].qty == 2,
        "a purchase adds to its slot, or takes a free one; a full tray takes only what it holds")
    local entry = { q = 12, base = 3 }
    local P = Buy.Pending
    check("IN-MAIL", P(entry, 3) == 12 and P(entry, 10) == 5 and P(entry, 15) == 0 and P(entry, 1) == 12,
        "12 bought with 3 in the bags: 12 in the mail; 10 in the bags: 5; 15: none; 1 (3 used): still 12")
    return passed, failed
end

for _, event in ipairs({ "COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE", "COMMODITY_PURCHASED",
    "COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED", "AUCTION_HOUSE_SHOW_ERROR", "ADDON_ACTION_BLOCKED",
    "ADDON_ACTION_FORBIDDEN", "PLAYER_REGEN_DISABLED" }) do
    ns.eventFrame:RegisterEvent(event)
end
