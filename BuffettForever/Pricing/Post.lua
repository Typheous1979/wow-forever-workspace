local addonName, ns = ...

-- Posting from BuffettForever (Justin, 2026-10-18: "post it on the AH if I have the auction house open"), at
-- the cheapest listing by others, from a search just before (his choice: Blizzard's own default, no undercut).
-- First /bf posttest, a probe of what no addon has done on Forever yet, typed so each call runs inside a key
-- press:
--   /bf posttest <itemID> [qty] [price]  at the AH: finds the item in your bags, logs what the game says about
--                                        posting it, and searches the price (the cheapest listing by others)
--                                        unless one is typed (copper each)
--   /bf posttest confirm                 posts it (PostCommodity, or PostItem for gear); after a warning, a
--                                        second confirm answers it (ConfirmPost*)
--   /bf posttest cancel                  drops it
-- Every step goes to diag.posts (the last 10): needsConfirmation, the warning and whether Blizzard's own popup
-- shows for an addon's post (it's left alone: hiding it from here would taint the shared popups), the
-- auction's creation and its timing, the errors, multisell for gear, the money spent.

local L = ns.L
local Money = ns.Money
local Post = {}
ns.Post = Post
local events = ns.events

local KEEP = 10              -- probes kept in diag.posts
local ANSWER_TIMEOUT = 15    -- seconds for a post's outcome
local POPUP_CHECK = 0.1      -- seconds after a warning: is Blizzard's popup up?

local state = "ready"        -- ready, pricing, planned, warned, posting
local post                   -- the open probe
local timer

local function Show(v)
    if ns.IsSecret(v) then return "secret" end
    return tostring(v)
end

-- pcall's answer for the log.
local function Value(ok, v)
    if not ok then return "error: " .. tostring(v) end
    return Show(v)
end

local function Step(text)
    if not post then return end
    post.steps[#post.steps + 1] = string.format("%.1fs %s", (debugprofilestop() - post.started) / 1000, text)
end

local function StopTimer()
    if timer then
        timer:Cancel()
        timer = nil
    end
end

local function Finish(outcome)
    local rec = post
    if not rec then return end
    StopTimer()
    Step("outcome " .. outcome)
    rec.outcome, rec.started, rec.location, rec.moneyAfter = outcome, nil, nil, GetMoney()
    post, state = nil, "ready"
    if ns.db and not ns.readOnlyDB then
        local list = ns.db.diag.posts or {}
        ns.db.diag.posts = list
        table.insert(list, 1, rec)
        while #list > KEEP do table.remove(list) end
    end
    ns.Print(string.format(L["Post test: %s; %s spent (logged)."], outcome, Money.Format(math.max(0, rec.moneyBefore - rec.moneyAfter))))
end

-- The first bag slot holding itemID, as an ItemLocation.
local function Find(itemID)
    for bag = Enum.BagIndex.Backpack, Enum.BagIndex.ReagentBag do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID == itemID then return ItemLocation:CreateFromBagAndSlot(bag, slot), bag, slot end
        end
    end
    return nil
end

-- Whether Blizzard's sell tab holds a post waiting for its own warning's Accept (read only).
local function BlizzardPending()
    local frame = AuctionHouseFrame
    if not frame then return false end
    local commodities, items = frame.CommoditiesSellFrame, frame.ItemSellFrame
    return (commodities ~= nil and commodities.pendingPost ~= nil) or (items ~= nil and items.pendingPost ~= nil)
end

local function PrintPlan(rec)
    local game = tonumber(rec.facts.depositGame)
    ns.Print(string.format(L["Post test: %d %s at %s each, %s; deposit %s (the formula: %s). /bf posttest confirm posts it."],
        rec.qty, ns.Items.Link(rec.itemID), Money.Format(rec.price), rec.facts.durationName,
        game and Money.Format(game) or rec.facts.depositGame, Money.Format(rec.facts.depositFormula)))
end

local function Plan(itemID, qty, price)
    if state ~= "ready" then
        ns.Print(L["A post test is open: /bf posttest confirm or cancel."])
        return
    end
    if not ns.ahOpen then
        ns.Print(L["Open the Auction House first."])
        return
    end
    if ns.Buy.IsBusy() then
        ns.Print(L["A purchase is open."])
        return
    end
    local location, bag, slot = Find(itemID)
    if not location then
        ns.Print(string.format(L["No %s in your bags."], ns.Items.Link(itemID)))
        return
    end
    local d = ns.Deposits.Duration()
    local okStatus, status = pcall(C_AuctionHouse.GetItemCommodityStatus, location)
    local commodity = okStatus and status == Enum.ItemCommodityStatus.Commodity
    local sell = ns.Deposits.VendorSell(itemID)
    local depositGame
    if commodity then
        depositGame = Value(pcall(C_AuctionHouse.CalculateCommodityDeposit, itemID, d, qty))
    else
        depositGame = Value(pcall(C_AuctionHouse.CalculateItemDeposit, location, d, qty))
    end
    post = { t = GetServerTime(), build = select(2, GetBuildInfo()), itemID = itemID, qty = qty, bag = bag, slot = slot,
             duration = d, commodity = commodity, location = location, steps = {}, started = debugprofilestop(),
             moneyBefore = GetMoney() }
    post.facts = {
        valid = Value(pcall(C_AuctionHouse.IsSellItemValid, location, false)),
        locked = Value(pcall(C_Item.IsLocked, location)),
        status = Value(okStatus, status),
        available = Value(pcall(C_AuctionHouse.GetAvailablePostCount, location)),
        depositGame = depositGame,
        depositFormula = commodity and ns.Econ.Deposit(sell, qty, d) or ns.Econ.Deposit(sell, 1, d) * qty,
        durationName = ns.Deposits.DurationName(d),
        copper = Value(pcall(C_AuctionHouse.SupportsCopperValues)),
        throttle = Value(pcall(C_AuctionHouse.IsThrottledMessageSystemReady)),
        blizzardPending = tostring(BlizzardPending()),
        vendorSell = sell,
    }
    local f = post.facts
    Step(string.format("bag %d slot %d: valid %s, locked %s, status %s, available %s; %s, deposit %s (formula %d); copper %s, throttle %s, Blizzard's pending post %s",
        bag, slot, f.valid, f.locked, f.status, f.available, f.durationName, f.depositGame, f.depositFormula, f.copper, f.throttle,
        f.blizzardPending))
    if price then
        post.price, post.typed = price, true
        state = "planned"
        PrintPlan(post)
        return
    end
    state = "pricing"
    local okKey, key = pcall(C_AuctionHouse.GetItemKeyFromItem, location)
    local rec = post
    ns.Print(string.format(L["Post test: checking the price of %s..."], ns.Items.Link(itemID)))
    ns.Search.Request(itemID, okKey and key or nil, function(_, result, problem)
        if post ~= rec or state ~= "pricing" then return end
        if not result or not result.min then
            Step("search: " .. tostring(problem))
            ns.Print(string.format(L["Post test: nobody else lists it (%s); type a price: /bf posttest %d %d <copper>."],
                tostring(problem), itemID, qty))
            Finish("no price")
            return
        end
        rec.price, rec.mv, rec.own = math.floor(result.min), result.mv, result.own
        Step(string.format("search: cheapest by others %s, market value %s, own %s", tostring(result.min), tostring(result.mv),
            tostring(result.own)))
        state = "planned"
        PrintPlan(rec)
    end)
end

local function Call(fn, name, ...)
    local ok, needs = pcall(fn, ...)
    Step(ok and string.format("%s called, needsConfirmation %s", name, Show(needs)) or string.format("%s error: %s", name, tostring(needs)))
    return ok, needs
end

-- Runs inside the typed confirm.
local function Confirm()
    if not post or (state ~= "planned" and state ~= "warned") then
        ns.Print(L["Nothing to confirm: /bf posttest <itemID> [qty] [price] first."])
        return
    end
    local p = post
    local location = p.location
    if not location or not C_Item.DoesItemExist(location) or C_Item.GetItemID(location) ~= p.itemID then
        location = Find(p.itemID)
        p.location = location
        Step("the item moved; found it again: " .. tostring(location ~= nil))
    end
    if not location then
        Finish("the item left your bags")
        return
    end
    local ok, needs
    if state == "planned" then
        p.postedAt = debugprofilestop()
        if p.commodity then
            ok, needs = Call(C_AuctionHouse.PostCommodity, "PostCommodity", location, p.duration, p.qty, p.price)
        else
            ok, needs = Call(C_AuctionHouse.PostItem, "PostItem", location, p.duration, p.qty, nil, p.price)
        end
        if not ok then
            Finish("post error")
            return
        end
        p.needsConfirmation = Show(needs)
        if needs == true then
            state = "warned"
            ns.Print(L["Post test: the Auction House asks to confirm this post. /bf posttest confirm again posts it."])
        else
            state = "posting"
        end
    else
        if p.commodity then
            ok = Call(C_AuctionHouse.ConfirmPostCommodity, "ConfirmPostCommodity", location, p.duration, p.qty, p.price)
        else
            ok = Call(C_AuctionHouse.ConfirmPostItem, "ConfirmPostItem", location, p.duration, p.qty, nil, p.price)
        end
        if not ok then
            Finish("confirm error")
            return
        end
        state = "posting"
    end
    StopTimer()
    timer = C_Timer.NewTimer(ANSWER_TIMEOUT, function()
        timer = nil
        if post then Finish("no answer: check your auctions") end
    end)
end

-- /bf posttest <itemID> [qty] [price] | confirm | cancel
function Post.Probe(msg)
    local arg1, arg2, arg3 = string.match(msg or "", "^%s*%S+%s*(%S*)%s*(%S*)%s*(%S*)")
    arg1 = string.lower(arg1 or "")
    if arg1 == "confirm" then
        Confirm()
    elseif arg1 == "cancel" then
        if state == "posting" then
            ns.Print(L["The post is on its way: it can't be called back."])
        else
            Finish("cancelled")
        end
    else
        local itemID, qty, price = tonumber(arg1), tonumber(arg2) or 1, tonumber(arg3)
        if not itemID or qty < 1 or (price and price < 1) then
            ns.Print(L["Usage: /bf posttest <itemID> [quantity] [price in copper], then /bf posttest confirm or cancel"])
            return
        end
        Plan(itemID, math.floor(qty), price and math.floor(price) or nil)
    end
end

-- ---------------------------------------------------------------- what a probe logs

local function Elapsed()
    return post and post.postedAt and string.format("%.0f ms after the post", debugprofilestop() - post.postedAt) or "-"
end

function events:AUCTION_HOUSE_POST_WARNING()
    if not post then return end
    Step("AUCTION_HOUSE_POST_WARNING " .. Elapsed() .. ": " .. tostring(_G["CONFIRM_AUCTION_POSTING_TEXT"]))
    C_Timer.After(POPUP_CHECK, function()
        if post then Step("Blizzard's warning popup shown: " .. tostring(StaticPopup_Visible("AUCTION_HOUSE_POST_WARNING") ~= nil)) end
    end)
end

function events:AUCTION_HOUSE_POST_ERROR()
    if not post then return end
    Step("AUCTION_HOUSE_POST_ERROR " .. Elapsed())
    Finish("post error")
end

function events:AUCTION_MULTISELL_START(total)
    Step("AUCTION_MULTISELL_START " .. Show(total))
end

function events:AUCTION_MULTISELL_UPDATE(created, total)
    if not post then return end
    Step(string.format("AUCTION_MULTISELL_UPDATE %s of %s, %s", Show(created), Show(total), Elapsed()))
    if state == "posting" and not ns.IsSecret(created) and not ns.IsSecret(total) and created == total then Finish("posted") end
end

function events:AUCTION_MULTISELL_FAILURE()
    if not post then return end
    Step("AUCTION_MULTISELL_FAILURE " .. Elapsed())
    Finish("multisell failed")
end

ns.On("AUCTION_CREATED", function(auctionID)
    if not post or state ~= "posting" then return end
    Step(string.format("AUCTION_HOUSE_AUCTION_CREATED %s, %s", Show(auctionID), Elapsed()))
    post.auctionID = auctionID
    if post.commodity or post.qty <= 1 then Finish("posted") end
end)

ns.On("AH_ERROR", function(err)
    if not post or (state ~= "posting" and state ~= "warned") then return end
    Step("AUCTION_HOUSE_SHOW_ERROR " .. Show(err))
    Finish("error " .. Show(err))
end)

ns.On("ACTION_BLOCKED", function(event, fn)
    if not post then return end
    Step(string.format("%s %s", event, tostring(fn)))
    Finish("blocked")
end)

ns.On("AH_CLOSED", function()
    if post then Finish("the Auction House closed") end
end)

-- /bf diag: the last probe.
function Post.PrintDiag()
    local rec = ns.db and ns.db.diag.posts and ns.db.diag.posts[1]
    if not rec then return end
    ns.Print(string.format("post test %s %d x%d at %s (%s): %s; needsConfirmation %s; money %s -> %s; %s", date("%H:%M:%S", rec.t),
        rec.itemID, rec.qty, tostring(rec.price), rec.commodity and "commodity" or "item", tostring(rec.outcome),
        tostring(rec.needsConfirmation), tostring(rec.moneyBefore), tostring(rec.moneyAfter), table.concat(rec.steps or {}, ", ")))
end

for _, event in ipairs({ "AUCTION_HOUSE_POST_WARNING", "AUCTION_HOUSE_POST_ERROR", "AUCTION_MULTISELL_START",
    "AUCTION_MULTISELL_UPDATE", "AUCTION_MULTISELL_FAILURE" }) do
    ns.eventFrame:RegisterEvent(event)
end
