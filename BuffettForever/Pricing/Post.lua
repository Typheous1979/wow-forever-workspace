local addonName, ns = ...

-- Posting what you crafted (Justin, 2026-10-18: "post it on the AH if I have the auction house open"), at the
-- cheapest listing by others, from a search just before (his choice: Blizzard's own default, no undercut).
-- PostCommodity posts from addon code on Forever [F-136]. The bar's Post (UI/CraftRow.lua) lists only what you
-- crafted that's still in your bags (Craft.Made), so stock you already had is never listed:
--   Post     -> a search of the item (Search.Request): the cheapest unit price by others and the market value;
--               the price, the deposit and what you'd get are shown, and hold 60 s
--   Confirm  -> PostCommodity(location, duration, qty, price), or PostItem for gear (one auction each, the
--               AUCTION_MULTISELL_* events) -> AUCTION_HOUSE_AUCTION_CREATED (Owned passes it on)
-- needsConfirmation true: the AH warns (AUCTION_HOUSE_POST_WARNING), and a third click (Confirm again) sends the
-- same post to ConfirmPostCommodity / ConfirmPostItem. Blizzard's own warning popup is left alone: its Accept
-- confirms only Blizzard's own pending post and does nothing for ours, and hiding it from here would taint the
-- shared popups. Refused when a vendor pays at least what a sale nets after the cut; a price under half the
-- market value shows in orange. The duration and deposit are the sell frame's (Deposits.Duration,
-- CalculateCommodityDeposit / CalculateItemDeposit, the formula when they don't answer). States: ready,
-- pricing, planned, warned, posting; Buy, Craft and Post exclude each other.
-- /bf posttest <itemID> [qty] [price] | confirm | cancel runs the same steps on any item in your bags. Every
-- step goes to diag.posts (the last 10).

local L = ns.L
local Money = ns.Money
local Post = {}
ns.Post = Post
local events = ns.events

local KEEP = 10              -- posts kept in diag.posts
local ANSWER_TIMEOUT = 15    -- seconds for a post's outcome
local POPUP_CHECK = 0.1      -- seconds after a warning: is Blizzard's popup up?
local HOLD = 60              -- seconds a price holds before it's looked at again
local LOW_SHARE = 0.5        -- under half the market value: shown in orange
local WHY_KEEP = 60          -- seconds a refusal stays in Post's tooltip

local state = "ready"        -- ready, pricing, planned, warned, posting
local post                   -- the open post
local timer, holdTimer
local blocked                -- why posting from here is off this session
local lastWhy                -- { itemID, text, t }: the last refusal, for the tooltip

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

local function Changed()
    ns.Fire("POST_CHANGED", state)
end

local function Cut()
    return (ns.Ledger.Cut())
end

-- ---------------------------------------------------------------- pure helpers (the self-test runs them)

-- The price to post at from a search result: the cheapest unit price by others (the search leaves your own out),
-- in whole copper; nil when nobody else lists it.
function Post.Price(result)
    if type(result) ~= "table" or type(result.min) ~= "number" or result.min < 1 then return nil end
    return math.floor(result.min)
end

-- What qty units at price bring if all sell: the cut is taken in whole copper, rounded down (a 19c sale paid
-- none [F-130]).
function Post.Net(price, qty, cut)
    local total = price * qty
    return total - math.floor(total * (cut or 0))
end

-- What the bar posts: what you crafted, at most what's in your bags.
function Post.Quantity(made, bags)
    return math.max(0, math.min(made or 0, bags or 0))
end

-- "refuse" when a vendor pays at least what one sells for after the cut, "low" under half the market value
-- (a troll price?), else "ok".
function Post.Check(price, cut, vendorSell, marketValue)
    if (vendorSell or 0) > 0 and Post.Net(price, 1, cut) <= vendorSell then return "refuse" end
    if marketValue and marketValue > 0 and price < marketValue * LOW_SHARE then return "low" end
    return "ok"
end

-- ---------------------------------------------------------------- the post

local function StopTimers()
    if timer then
        timer:Cancel()
        timer = nil
    end
    if holdTimer then
        holdTimer:Cancel()
        holdTimer = nil
    end
end

local function Name(itemID)
    return C_Item.GetItemNameByID(itemID) or ("item " .. itemID)
end

local function Finish(outcome)
    local rec = post
    if not rec then return end
    StopTimers()
    Step("outcome " .. outcome)
    rec.outcome, rec.started, rec.location, rec.moneyAfter = outcome, nil, nil, GetMoney()
    post, state = nil, "ready"
    if ns.db and not ns.readOnlyDB then
        local list = ns.db.diag.posts or {}
        ns.db.diag.posts = list
        table.insert(list, 1, rec)
        while #list > KEEP do table.remove(list) end
    end
    local posted = rec.posted or 0
    if posted > 0 then
        if rec.kind == "bar" then ns.Craft.UseMade(rec.itemID, posted) end
        ns.Print(string.format(L["Posted %d %s at %s each, for a %s deposit."], posted, ns.Items.Link(rec.itemID),
            Money.Format(rec.price), Money.Format(rec.deposit or 0)))
    elseif rec.kind == "probe" then
        ns.Print(string.format(L["Post test: %s (logged)."], outcome))
    end
    -- The money read later: the deposit isn't taken by the time the auction is created [F-136].
    C_Timer.After(2, function() rec.moneyLater = GetMoney() end)
    Changed()
end

-- A refusal the bar's tooltip keeps showing for a while.
local function Refuse(itemID, text)
    lastWhy = { itemID = itemID, text = text, t = GetTime() }
    ns.Print(text)
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

-- Whether Blizzard's sell tab holds a post waiting for its own warning's Accept (read only): that Accept would
-- confirm it, not ours.
local function BlizzardPending()
    local frame = AuctionHouseFrame
    if not frame then return false end
    local commodities, items = frame.CommoditiesSellFrame, frame.ItemSellFrame
    return (commodities ~= nil and commodities.pendingPost ~= nil) or (items ~= nil and items.pendingPost ~= nil)
end

-- The post's record: the item's bag slot, the duration and deposit, and what the game says about posting it.
local function Begin(kind, itemID, qty, recipeID)
    local location, bag, slot = Find(itemID)
    if not location then return nil, string.format(L["No %s in your bags."], ns.Items.Link(itemID)) end
    local d = ns.Deposits.Duration()
    local okStatus, status = pcall(C_AuctionHouse.GetItemCommodityStatus, location)
    local commodity = okStatus and status == Enum.ItemCommodityStatus.Commodity
    local sell = ns.Deposits.VendorSell(itemID)
    local okDeposit, deposit
    if commodity then
        okDeposit, deposit = pcall(C_AuctionHouse.CalculateCommodityDeposit, itemID, d, qty)
    else
        okDeposit, deposit = pcall(C_AuctionHouse.CalculateItemDeposit, location, d, qty)
    end
    local formula = commodity and ns.Econ.Deposit(sell, qty, d) or ns.Econ.Deposit(sell, 1, d) * qty
    post = { t = GetServerTime(), build = select(2, GetBuildInfo()), kind = kind, itemID = itemID, qty = qty,
             recipeID = recipeID, bag = bag, slot = slot, duration = d, commodity = commodity, location = location,
             vendorSell = sell, steps = {}, started = debugprofilestop(), moneyBefore = GetMoney() }
    post.deposit = (okDeposit and type(deposit) == "number" and not ns.IsSecret(deposit)) and deposit or formula
    post.facts = {
        valid = Value(pcall(C_AuctionHouse.IsSellItemValid, location, false)),
        locked = Value(pcall(C_Item.IsLocked, location)),
        status = Value(okStatus, status),
        available = Value(pcall(C_AuctionHouse.GetAvailablePostCount, location)),
        depositGame = Value(okDeposit, deposit),
        depositFormula = formula,
        durationName = ns.Deposits.DurationName(d),
        copper = Value(pcall(C_AuctionHouse.SupportsCopperValues)),
        throttle = Value(pcall(C_AuctionHouse.IsThrottledMessageSystemReady)),
        blizzardPending = tostring(BlizzardPending()),
    }
    local f = post.facts
    Step(string.format("bag %d slot %d: valid %s, locked %s, status %s, available %s; %s, deposit %s (formula %d); copper %s, throttle %s, Blizzard's pending post %s",
        bag, slot, f.valid, f.locked, f.status, f.available, f.durationName, f.depositGame, f.depositFormula, f.copper, f.throttle,
        f.blizzardPending))
    return post
end

-- The price is shown: Confirm posts it within HOLD seconds.
local function Planned(rec)
    state = "planned"
    if holdTimer then holdTimer:Cancel() end
    holdTimer = C_Timer.NewTimer(HOLD, function()
        holdTimer = nil
        if post ~= rec or state ~= "planned" then return end
        ns.Print(L["The price is over a minute old: Post looks it up again."])
        Finish("the price is over a minute old")
    end)
    if rec.kind == "probe" then
        ns.Print(string.format(L["Post test: %d %s at %s each, %s; deposit %s. /bf posttest confirm posts it."], rec.qty,
            ns.Items.Link(rec.itemID), Money.Format(rec.price), rec.facts.durationName, Money.Format(rec.deposit)))
    end
    Changed()
end

-- The search's answer: the price, and for the bar the check against what a vendor pays.
local function Priced(rec, result, problem)
    if post ~= rec or state ~= "pricing" then return end
    local price = Post.Price(result)
    if not price then
        Step("search: " .. tostring(problem))
        Refuse(rec.itemID, string.format(L["Nobody else lists %s (%s): set a price in the Sell tab."], Name(rec.itemID),
            tostring(problem)))
        Finish("no price")
        return
    end
    rec.price, rec.mv, rec.own, rec.searchedAt = price, result.mv, result.own, GetTime()
    Step(string.format("search: cheapest by others %s, market value %s, own %s", tostring(result.min), tostring(result.mv),
        tostring(result.own)))
    if not rec.typed then
        rec.check = Post.Check(price, Cut(), rec.vendorSell, result.mv)
        if rec.check == "refuse" and rec.kind == "bar" then
            Refuse(rec.itemID, string.format(L["A vendor pays more for %s: %s each, against %s after the cut."], Name(rec.itemID),
                Money.Format(rec.vendorSell), Money.Format(Post.Net(price, 1, Cut()))))
            Finish("refused: a vendor pays more")
            return
        end
    end
    Planned(rec)
end

local function Price(rec)
    state = "pricing"
    local okKey, key = pcall(C_AuctionHouse.GetItemKeyFromItem, rec.location)
    ns.Search.Request(rec.itemID, okKey and key or nil, function(_, result, problem) Priced(rec, result, problem) end)
    Changed()
end

function Post.State()
    return state, post
end

-- A post is open (Buy and Craft wait for it).
function Post.IsBusy()
    return state ~= "ready"
end

-- The last refusal for itemID, while it's recent.
function Post.LastWhy(itemID)
    if lastWhy and lastWhy.itemID == itemID and GetTime() - lastWhy.t < WHY_KEEP then return lastWhy.text end
    return nil
end

function Post.Cut()
    return Cut()
end

-- Whether the bar's Post can start for result r, why not, and how many it would post (what you crafted that's
-- in your bags).
function Post.CanStart(r)
    local recipe = r and r.recipe
    if not recipe then return false, nil, 0 end
    local n = ns.Craft.Made(recipe.output)
    if not ns.ahOpen then return false, L["Open the Auction House (talk to an auctioneer) to post."], n end
    if ns.InCombat() then return false, L["Not in combat."], n end
    if state ~= "ready" then return false, L["A post is open."], n end
    if ns.Buy.IsBusy() then return false, L["A purchase is open."], n end
    if ns.Craft.IsBusy() then return false, L["A craft is under way."], n end
    if ns.Scanner.IsBusy() then return false, L["A full scan is running."], n end
    if recipe.bop then return false, L["It binds when picked up: it can't be sold."], n end
    local location = n > 0 and Find(recipe.output)
    if not location then return false, L["Nothing you crafted is in your bags: Create first."], 0 end
    local okValid, valid = pcall(C_AuctionHouse.IsSellItemValid, location, false)
    if okValid and valid == false then return false, L["The Auction House won't take it."], n end
    local okLocked, locked = pcall(C_Item.IsLocked, location)
    if okLocked and locked == true then return false, L["It's in use: a moment."], n end
    if BlizzardPending() then return false, L["Blizzard's Sell tab has a post waiting: finish or cancel it there."], n end
    if blocked then return false, L["Forever blocked posting from an addon: post it from the Sell tab."], n end
    return true, nil, n
end

-- The bar's Post, inside the click: what you crafted, priced by a search first.
function Post.Start(r)
    local ok, why, n = Post.CanStart(r)
    if not ok then
        if why then ns.Print(why) end
        return false
    end
    local rec, err = Begin("bar", r.recipe.output, n, r.recipe.recipeID)
    if not rec then
        ns.Print(err)
        return false
    end
    Price(rec)
    return true
end

local function Call(fn, name, ...)
    local ok, needs = pcall(fn, ...)
    Step(ok and string.format("%s called, needsConfirmation %s", name, Show(needs)) or string.format("%s error: %s", name, tostring(needs)))
    return ok, needs
end

-- Confirm (and Confirm again after a warning), inside the click.
function Post.Confirm()
    if not post or (state ~= "planned" and state ~= "warned") then
        if post == nil then ns.Print(L["Nothing to confirm: Post first."]) end
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
    if GetMoney() < (p.deposit or 0) then
        ns.Print(string.format(L["Not enough gold for the %s deposit."], Money.Format(p.deposit)))
        return
    end
    if not C_AuctionHouse.IsThrottledMessageSystemReady() then
        ns.Print(L["The Auction House is busy: a moment."])
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
            StopTimers()
            ns.Print(L["The Auction House asks to confirm this post: Confirm again posts it (Blizzard's own popup can't, so close it)."])
            Changed()
            return
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
    end
    state = "posting"
    StopTimers()
    timer = C_Timer.NewTimer(ANSWER_TIMEOUT, function()
        timer = nil
        if not post then return end
        ns.Print(L["No answer to the post: check your auctions."])
        Finish("no answer")
    end)
    Changed()
end

-- why: said in chat and logged (nil: the player's own Cancel, inside the click). A gear post under way stops
-- with CancelSell (only from the click); a commodity's is out already.
function Post.Cancel(why)
    if state == "ready" or not post then return end
    if state == "posting" then
        if not why and post.multisell then
            local ok = pcall(C_AuctionHouse.CancelSell)
            Step(ok and "CancelSell called" or "CancelSell error")
        end
        return
    end
    if why then ns.Print(string.format(L["Post cancelled: %s."], why)) end
    Finish(why or "cancelled")
end

-- ---------------------------------------------------------------- what the bar shows

local GREY, ORANGE = "|cff999999", "|cffff9933"

-- The status line while a post is open, or nil.
function Post.StatusText()
    local p = post
    if state == "ready" or not p then return nil end
    local icon = C_Item.GetItemIconByID(p.itemID)
    icon = icon and string.format("|T%s:14:14|t ", icon) or ""
    if state == "pricing" then return icon .. GREY .. string.format(L["Checking the price of %s..."], Name(p.itemID)) .. "|r" end
    if state == "posting" then return icon .. string.format(L["Posting %d %s..."], p.qty, Name(p.itemID)) end
    if state == "warned" then return ORANGE .. L["The Auction House asks to confirm: Confirm again posts it."] .. "|r" end
    local text = string.format(L["%d at %s: deposit %s, %s if all sell"], p.qty, Money.Compact(p.price), Money.Compact(p.deposit),
        Money.Compact(Post.Net(p.price, p.qty, Cut())))
    if p.check == "low" then return icon .. ORANGE .. text .. " " .. L["(under half its market value)"] .. "|r" end
    return icon .. text
end

-- ---------------------------------------------------------------- /bf posttest

-- /bf posttest <itemID> [qty] [price] | confirm | cancel
function Post.Probe(msg)
    local arg1, arg2, arg3 = string.match(msg or "", "^%s*%S+%s*(%S*)%s*(%S*)%s*(%S*)")
    arg1 = string.lower(arg1 or "")
    if arg1 == "confirm" then
        Post.Confirm()
        return
    elseif arg1 == "cancel" then
        Post.Cancel()
        return
    end
    local itemID, qty, price = tonumber(arg1), tonumber(arg2) or 1, tonumber(arg3)
    if not itemID or qty < 1 or (price and price < 1) then
        ns.Print(L["Usage: /bf posttest <itemID> [quantity] [price in copper], then /bf posttest confirm or cancel"])
        return
    end
    if state ~= "ready" then
        ns.Print(L["A post is open: /bf posttest confirm or cancel."])
        return
    end
    if not ns.ahOpen then
        ns.Print(L["Open the Auction House first."])
        return
    end
    if ns.Buy.IsBusy() or ns.Craft.IsBusy() then
        ns.Print(L["A purchase or a craft is open."])
        return
    end
    local rec, err = Begin("probe", itemID, math.floor(qty))
    if not rec then
        ns.Print(err)
        return
    end
    if price then
        rec.price, rec.typed = math.floor(price), true
        Planned(rec)
    else
        ns.Print(string.format(L["Post test: checking the price of %s..."], ns.Items.Link(itemID)))
        Price(rec)
    end
end

-- ---------------------------------------------------------------- events

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
    if not post or (state ~= "posting" and state ~= "warned") then return end
    Step("AUCTION_HOUSE_POST_ERROR " .. Elapsed())
    ns.Print(L["The Auction House refused the post: nothing was listed."])
    Finish("post error")
end

function events:AUCTION_MULTISELL_START(total)
    if not post then return end
    post.multisell = true
    Step("AUCTION_MULTISELL_START " .. Show(total))
end

function events:AUCTION_MULTISELL_UPDATE(created, total)
    if not post or state ~= "posting" then return end
    Step(string.format("AUCTION_MULTISELL_UPDATE %s of %s, %s", Show(created), Show(total), Elapsed()))
    if ns.IsSecret(created) or ns.IsSecret(total) then return end
    post.posted = created
    if created == total then Finish("posted") end
end

function events:AUCTION_MULTISELL_FAILURE()
    if not post or state ~= "posting" then return end
    Step("AUCTION_MULTISELL_FAILURE " .. Elapsed())
    Finish(string.format("posted %d of %d", post.posted or 0, post.qty))
end

ns.On("AUCTION_CREATED", function(auctionID)
    if not post or state ~= "posting" then return end
    Step(string.format("AUCTION_HOUSE_AUCTION_CREATED %s, %s", Show(auctionID), Elapsed()))
    post.auctionID = auctionID
    if post.commodity or post.qty <= 1 then
        post.posted = post.qty
        Finish("posted")
    end
end)

ns.On("AH_ERROR", function(err)
    if not post or (state ~= "posting" and state ~= "warned") then return end
    Step("AUCTION_HOUSE_SHOW_ERROR " .. Show(err))
    ns.Print(string.format(L["The Auction House refused the post (error %s): nothing was listed."], Show(err)))
    Finish("error " .. Show(err))
end)

ns.On("ACTION_BLOCKED", function(event, fn)
    if not post then return end
    blocked = tostring(fn)
    Step(string.format("%s %s", event, tostring(fn)))
    ns.Print(L["Forever blocked posting from an addon: post it from the Sell tab."])
    Finish("blocked")
end)

ns.On("AH_CLOSED", function()
    if not post then return end
    if state == "posting" then
        ns.Print(L["The Auction House closed during the post: check your auctions."])
        Finish("the Auction House closed while posting")
    else
        Post.Cancel(L["the Auction House closed"])
    end
end)

ns.On("COMBAT_STARTED", function()
    if post and state ~= "posting" then Post.Cancel(L["combat"]) end
end)

-- Another recipe or view while a price is shown: it was for the one before.
ns.On("DETAILS_SHOWN", function(_, changed)
    if changed and post and post.kind == "bar" and state ~= "posting" then Post.Cancel(L["another recipe was picked"]) end
end)

-- /bf diag: the last post.
function Post.PrintDiag()
    local rec = ns.db and ns.db.diag.posts and ns.db.diag.posts[1]
    if rec then
        ns.Print(string.format("post %s %s %d x%d at %s (%s): %s; needsConfirmation %s; money %s -> %s (later %s); %s",
            date("%H:%M:%S", rec.t), tostring(rec.kind), rec.itemID, rec.qty, tostring(rec.price),
            rec.commodity and "commodity" or "item", tostring(rec.outcome), tostring(rec.needsConfirmation),
            tostring(rec.moneyBefore), tostring(rec.moneyAfter), tostring(rec.moneyLater), table.concat(rec.steps or {}, ", ")))
    end
    if blocked then ns.Print("posting from here is off this session: " .. blocked) end
end

-- ---------------------------------------------------------------- self-test

function Post.SelfTest(report)
    local passed, failed = 0, 0
    local function check(name, ok, detail)
        if ok then passed = passed + 1 else failed = failed + 1 end
        report(name, ok, detail)
    end
    local P = Post.Price
    check("POST-PRICE", P({ min = 74 }) == 74 and P({ min = 1234.6 }) == 1234 and P({}) == nil and P(nil) == nil,
        "the cheapest by others, in whole copper (74, 1234.6 -> 1234); nobody else: no price")
    local N = Post.Net
    check("POST-NET", N(19, 1, 0.05) == 19 and N(74, 10, 0.05) == 703 and N(100, 3, 0.05) == 285,
        "the cut in whole copper, rounded down: 19c keeps 19c; 10 at 74c: 703c; 3 at 1s: 2s 85c")
    local Q = Post.Quantity
    check("POST-QTY", Q(5, 3) == 3 and Q(2, 9) == 2 and Q(0, 4) == 0 and Q(nil, 4) == 0,
        "what you crafted, at most what's in your bags (5 made, 3 left: 3; 2 of 9: 2; none made: 0)")
    local C = Post.Check
    check("POST-GUARD", C(74, 0.05, 15, 76) == "ok" and C(15, 0.05, 15, 76) == "refuse" and C(16, 0.05, 15, 76) == "low"
        and C(30, 0.05, 0, 100) == "low" and C(100, 0.05, 0, nil) == "ok",
        "refused when a vendor pays at least the sale after the cut; under half the market value: low")
    return passed, failed
end

for _, event in ipairs({ "AUCTION_HOUSE_POST_WARNING", "AUCTION_HOUSE_POST_ERROR", "AUCTION_MULTISELL_START",
    "AUCTION_MULTISELL_UPDATE", "AUCTION_MULTISELL_FAILURE" }) do
    ns.eventFrame:RegisterEvent(event)
end
