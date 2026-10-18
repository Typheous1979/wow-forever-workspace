local addonName, ns = ...

-- Crafting evaluation (wowf-economics crafting-economics.md and risk-and-recommendation.md). For one
-- recipe and N crafts:
-- - what the reagents cost: owned stock first, valued per the owned-materials policy, then the rest
--   from the cheapest of vendor, AH ladder or a recipe this character knows (make-or-buy, depth 3);
-- - what the output fetches: the vendor, or the AH after the cut and the expected deposit loss
--   (the item's own deposit and sale chance; floored at 0); the AH is chosen only when it beats the
--   vendor by the margin of safety;
-- - profit, ROI, value added over selling the inputs raw, and a confidence grade;
-- - whether to recommend it, and the reasons when not.
-- Evaluate() reads only its context table, so /bf selftest runs the reference vectors on mock
-- contexts. LiveContext() builds the real one from PriceDB, Merchant, the bags and known recipes.
-- Context tables (indexed by itemID): vendorBuy, vendorSell, sellPrice (conservative AH unit price),
-- ladder, recipeFor ({ yield, reagents = { id, qty, ... } }), owned, deposit (optional per-unit
-- figures; without one, Forever's formula for settings.duration), commodity (optional: false = one
-- auction per unit), saleChance (optional: settings.saleChance when absent), priceInfo ({ age, days,
-- observations, cv, listed }); plus settings (cut = the measured house cut once there is one,
-- duration = the auction duration 1-3, nil = no deposits).

local L = ns.L
local Econ = ns.Econ
local Evaluator = {}
ns.Evaluator = Evaluator

local GRADES = { "A", "B", "C", "D" }
local STALE = 48 * 3600     -- older AH data: fair value instead of the latest scan

-- The grade of one AH price, and the test that set it (Econ.Grade). exit: a price you'd sell at, where
-- a wall that never shrinks counts unless you've sold the item yourself (priceInfo.stale, .sold).
local function Grade(ctx, itemID, need, exit)
    local info = ctx.priceInfo[itemID]
    if not info then return "D", "unlisted" end
    local stale = exit and (info.sold or 0) == 0 and info.stale or nil
    return Econ.Grade(info.age, info.days, info.observations, info.cv, info.listed, need, stale)
end

-- The deposit per unit when selling qty units of itemID: the context's own figure if it has one,
-- else Forever's formula for the settings' auction duration (a commodity as one auction of qty, gear
-- one auction each; Econ.DepositPerUnit), else 0.
local function DepositUnit(ctx, itemID, qty)
    local deposit = ctx.deposit[itemID]
    if deposit then return deposit end
    local duration = ctx.settings.duration
    if not duration then return 0 end
    local commodity = not (ctx.commodity and ctx.commodity[itemID] == false)
    return Econ.DepositPerUnit(ctx.vendorSell[itemID] or 0, qty, duration, commodity)
end

-- What one unit nets on the AH when selling qty, with its own deposit and sale chance, floored at
-- 0: a listing that loses more in deposits than it earns is worth nothing there. nil when there's no
-- AH price.
local function AHUnit(ctx, itemID, qty)
    local s = ctx.settings
    local p = ctx.saleChance and ctx.saleChance[itemID] or s.saleChance
    local net = Econ.AHNet(ctx.sellPrice[itemID] or nil, s.cut, DepositUnit(ctx, itemID, qty), p)
    if net and net < 0 then net = 0 end
    return net
end

-- Per-unit liquidation value of qty units (the better of vendor and AH net), and whether the AH set it.
local function Liquidation(ctx, itemID, qty)
    local vendor = ctx.vendorSell[itemID] or nil
    local ahNet = AHUnit(ctx, itemID, qty)
    return Econ.Liquidation(vendor, ahNet), ahNet ~= nil and (not vendor or ahNet > vendor)
end

-- recipe: { recipeID, output, count (yield per craft), bop, reagents = { { itemID, count } } }.
function Evaluator.Evaluate(recipe, crafts, ctx)
    local s = ctx.settings
    local r = { recipe = recipe, crafts = crafts, units = recipe.count * crafts, lines = {}, warnings = {}, reasons = {} }
    local cogs, liquidation, complete, worst, ownedAny = 0, 0, true, 1, false
    -- The recipe's grade is its weakest AH price; remember which one and why (r.gradeWhy).
    local function note(itemID, need, exit)
        local grade, why = Grade(ctx, itemID, need, exit)
        local rank = Econ.GRADE_RANK[grade]
        if rank > worst then
            worst = rank
            r.gradeWhy = { itemID = itemID, reason = why, need = need, info = ctx.priceInfo[itemID] or nil }
        end
    end

    for _, g in ipairs(recipe.reagents) do
        local itemID, need = g.itemID, g.count * crafts
        local line = { itemID = itemID, need = need, owned = 0, ownedCost = 0, buyCost = 0 }
        local unitLiq, fromAH = Liquidation(ctx, itemID, need)
        local owned = math.min(need, ctx.owned[itemID] or 0)
        if owned > 0 then
            ownedAny = true
            line.owned = owned
            local unit
            if s.ownedPolicy == "free" then
                unit = 0
            elseif s.ownedPolicy == "replacement" then
                local cost = Econ.Acquire(itemID, owned, ctx)
                unit = cost and cost / owned
            else
                unit = unitLiq
                if unit and fromAH then note(itemID, nil) end
            end
            if unit then
                line.ownedCost = owned * unit
            else
                r.warnings[#r.warnings + 1] = { "unknownValue", itemID }
            end
        end
        local rest = need - owned
        line.rest = rest
        if rest > 0 then
            local cost, source = Econ.Acquire(itemID, rest, ctx)
            if cost then
                line.buyCost, line.source = cost, source
                if source == "ah" then note(itemID, rest) end
            else
                complete = false
                local ladder = ctx.ladder[itemID]
                if ladder then
                    local _, _, available = Econ.CostToBuy(ladder, rest)
                    r.warnings[#r.warnings + 1] = { "cantFill", itemID, available, rest }
                else
                    r.warnings[#r.warnings + 1] = { "noPrice", itemID }
                end
            end
        end
        line.cost = line.ownedCost + line.buyCost
        cogs = cogs + line.cost
        liquidation = liquidation + need * (unitLiq or 0)
        r.lines[#r.lines + 1] = line
    end

    -- Exits.
    local vendorUnit = ctx.vendorSell[recipe.output] or nil
    r.vendorExit = vendorUnit and vendorUnit * r.units
    if not recipe.bop then
        local unit = AHUnit(ctx, recipe.output, r.units)
        if unit then
            r.ahUnit = unit
            r.ahExit = unit * r.units
            -- for the details pane: the price before the cut, and the deposit per unit
            r.ahPrice, r.ahDeposit = ctx.sellPrice[recipe.output], DepositUnit(ctx, recipe.output, r.units)
        end
    end
    if r.ahExit and (not r.vendorExit or r.ahExit >= r.vendorExit * (1 + s.margin)) then
        r.best, r.bestSource = r.ahExit, "ah"
        note(recipe.output, nil, true)
    elseif r.vendorExit then
        r.best, r.bestSource = r.vendorExit, "vendor"
        r.underMargin = r.ahExit ~= nil and r.ahExit > r.vendorExit
    end

    r.cogs, r.complete, r.liquidation = cogs, complete, liquidation
    if r.best and complete then
        r.profit = r.best - cogs
        r.roi = Econ.ROI(r.profit, cogs)
    end
    if r.best then r.valueAdded = r.best - liquidation end
    r.grade = GRADES[worst]

    -- Margin of safety (risk-and-recommendation.md).
    local reasons = r.reasons
    if not complete then reasons[#reasons + 1] = "noReagentPrice" end
    if not r.best then reasons[#reasons + 1] = "noExit" end
    if r.profit then
        if r.profit < 0 then
            reasons[#reasons + 1] = "loss"
        else
            if r.roi and r.roi < s.margin then reasons[#reasons + 1] = "roiUnderMargin" end
            if r.profit / crafts < s.minProfit then reasons[#reasons + 1] = "underMinProfit" end
        end
    end
    if Econ.GRADE_RANK[r.grade] > Econ.GRADE_RANK[s.minGrade] then reasons[#reasons + 1] = "thinData" end
    if ownedAny and r.valueAdded and r.valueAdded < s.margin * liquidation and r.profit and r.profit >= 0 then
        reasons[#reasons + 1] = "sellRaw"
    end
    r.recommended = #reasons == 0
    return r
end

-- Batch size (risk-and-recommendation.md "Liquidity and saturation"), from two independent limits:
-- - best: as far as the reagents go, the batch with the most profit (the smallest on a tie), searched
--   from 1 to BATCH_LIMIT crafts and stopping where the reagents can't all be had (searched = the last
--   batch tried);
-- - cap: when the AH is the exit at this batch, a quarter of what's listed, in crafts (at least 1).
-- size is the smaller; limit says which set it: "reagents", "market", or "none" when profit still grows
-- at BATCH_LIMIT and no cap is smaller. Returns { best, profit, cap, size, limit, searched }.
local CAP_SHARE, BATCH_LIMIT = 0.25, 200
Evaluator.BATCH_LIMIT = BATCH_LIMIT

function Evaluator.BatchAdvice(recipe, crafts, ctx)
    local best, bestProfit, searched = nil, nil, 0
    for n = 1, BATCH_LIMIT do
        local r = Evaluator.Evaluate(recipe, n, ctx)
        if not r.complete then break end
        searched = n
        if r.profit and (not bestProfit or r.profit > bestProfit + 1e-9) then best, bestProfit = n, r.profit end
    end
    local cap
    if Evaluator.Evaluate(recipe, crafts, ctx).bestSource == "ah" then
        local info = ctx.priceInfo[recipe.output]
        local listed = info and info.listed or 0
        if listed > 0 then cap = math.max(1, math.floor(listed * CAP_SHARE / recipe.count)) end
    end
    local size, limit
    if best then
        if cap and cap < best then
            size, limit = cap, "market"
        elseif best >= BATCH_LIMIT then
            size, limit = best, "none"
        else
            size, limit = best, "reagents"
        end
    end
    return { best = best, profit = bestProfit, cap = cap, size = size, limit = limit, searched = searched }
end

-- Recommended first, then by ROI (nothing spent = infinite; unknown profit = last), then profit.
local function RankKey(r)
    if not r.profit then return -math.huge end
    return r.roi or math.huge
end

function Evaluator.Rank(results)
    table.sort(results, function(a, b)
        if a.recommended ~= b.recommended then return a.recommended end
        local ka, kb = RankKey(a), RankKey(b)
        if ka ~= kb then return ka > kb end
        local pa, pb = a.profit or -math.huge, b.profit or -math.huge
        if pa ~= pb then return pa > pb end
        return a.recipe.recipeID < b.recipe.recipeID
    end)
    return results
end

-- ---------------------------------------------------------------- the live context

local function Lazy(fn)
    return setmetatable({}, { __index = function(t, k)
        local v = fn(k)
        if v == nil then v = false end
        rawset(t, k, v)
        return v
    end })
end

local function Row(itemID)
    local row, age = ns.PriceDB.Get(itemID)
    return row, age
end

-- Context over this character's data; lookups are cached for one evaluation run. The settings are a
-- copy carrying the house cut measured from your sales mail once there is one (Pricing/Ledger.lua),
-- and the auction duration Blizzard's sell frame will use (deposits by Forever's formula).
function Evaluator.LiveContext()
    local today = ns.PriceDB.Today()
    local settings = {}
    for k, v in pairs(ns.db.settings) do settings[k] = v end
    settings.cut = (ns.Ledger.Cut())
    settings.duration = ns.Deposits.Duration()
    local ctx = { settings = settings }
    ctx.vendorBuy = Lazy(function(itemID) return (ns.Merchant.Get(itemID)) end)
    ctx.vendorSell = Lazy(function(itemID)
        local sell = ns.ItemSellPrice and ns.ItemSellPrice[itemID]
        if not sell then sell = select(11, C_Item.GetItemInfo(itemID)) end
        if type(sell) == "number" and sell > 0 then return sell end
        return nil
    end)
    -- Selling: the lower of market value and min buyout; the fair value once the scan is stale.
    -- An item a vendor sells is worth at most the vendor's price: nobody pays more on the AH
    -- (Coarse Thread listed at 19c sells for 10c at a vendor).
    ctx.sellPrice = Lazy(function(itemID)
        local row, age = Row(itemID)
        if not row then return nil end
        local price
        if age <= STALE then
            price = math.min(row.mv, row.min)
        else
            local fair = Econ.FairValue((ns.PriceDB.History(row)), today, 3, ns.db.settings.historyDays)
            price = fair and math.min(fair, row.min) or nil
        end
        local vendor = ctx.vendorBuy[itemID]
        if price and vendor and vendor < price then price = vendor end
        return price
    end)
    -- Buying: the latest ladder; once stale, one level at the fair value (the grade says so).
    ctx.ladder = Lazy(function(itemID)
        local row, age = Row(itemID)
        if not row or not row.ladder then return nil end
        if age <= STALE then return ns.PriceDB.UnpackLadder(row.ladder) end
        local fair = Econ.FairValue((ns.PriceDB.History(row)), today, 3, ns.db.settings.historyDays)
        return fair and { fair, row.q or 0 } or nil
    end)
    -- stale: days the cheapest price has held while the quantity never fell (a wall); sold: your own
    -- units sold (the ledger), which prove demand.
    ctx.priceInfo = Lazy(function(itemID)
        local row, age = Row(itemID)
        if not row then return nil end
        local window = ns.db.settings.historyDays
        local history, days, observations = ns.PriceDB.History(row)
        local _, cv = Econ.Volatility(history, today, window)
        local item = ns.Ledger.Item(itemID)
        return { age = age, days = days, observations = observations, cv = days > 1 and cv or nil, listed = row.q or 0,
                 stale = (ns.PriceDB.StaleRun(row, today, window)), sold = item and item.s or 0 }
    end)
    ctx.owned = Lazy(function(itemID) return C_Item.GetItemCount(itemID, true) end)
    -- Deposits come from Forever's formula (settings.duration, the batch size, commodity or not);
    -- no per-item figures.
    ctx.deposit = {}
    ctx.commodity = Lazy(function(itemID) return ns.Deposits.IsCommodity(itemID) end)
    -- From your sales mail: the item's own sold and expired units, pulled toward your rate over all items.
    ctx.saleChance = Lazy(function(itemID) return (ns.Ledger.SaleChance(itemID)) end)
    -- Make-or-buy only through recipes this character knows; the highest yield wins.
    ctx.recipeFor = Lazy(function(itemID)
        local best
        for _, recipeID in ipairs(ns.RecipeIndex.Making(itemID, { known = "char" })) do
            local recipe = ns.RecipeIndex.Get(recipeID)
            if not best or recipe.count > best.count then best = recipe end
        end
        if not best then return nil end
        local flat = {}
        for _, g in ipairs(best.reagents) do
            flat[#flat + 1] = g.itemID
            flat[#flat + 1] = g.count
        end
        return { yield = best.count, reagents = flat, recipeID = best.recipeID }
    end)
    return ctx
end

-- The tray's items in slot order, and its units per item. tray: { { itemID, qty } }.
local function TrayQty(tray)
    local ids, qty = {}, {}
    for _, e in ipairs(tray) do
        if not qty[e.itemID] then ids[#ids + 1] = e.itemID end
        qty[e.itemID] = (qty[e.itemID] or 0) + e.qty
    end
    return ids, qty
end

-- The crafts the tray quantities allow (qty: { [itemID] = units }), at least 1: a tray reagent a vendor
-- sells doesn't cap the batch (the vendor has more) unless it is all the tray offers. A recipe using none
-- of the tray's reagents: 1.
function Evaluator.TrayCrafts(recipe, qty, vendorSold)
    local crafts, vendorCrafts
    for _, g in ipairs(recipe.reagents) do
        local have = qty[g.itemID]
        if have then
            local n = math.floor(have / g.count)
            if vendorSold(g.itemID) then
                vendorCrafts = vendorCrafts and math.min(vendorCrafts, n) or n
            else
                crafts = crafts and math.min(crafts, n) or n
            end
        end
    end
    return math.max(1, crafts or vendorCrafts or 1)
end

-- Every recipe that uses the tray's reagents, plus every recipe made entirely from goods a vendor
-- sells (those are craftable whatever the tray holds), evaluated for the crafts the tray allows
-- (TrayCrafts) and ranked; and the context the results came from. tray: { { itemID, qty } }.
-- filter: RecipeIndex filter.
function Evaluator.ForTray(tray, filter)
    local ids, qty = TrayQty(tray)
    local ctx = Evaluator.LiveContext()
    local candidates, vendorOnly = {}, {}
    for _, recipeID in ipairs(ns.RecipeIndex.UsingAny(ids, filter)) do candidates[#candidates + 1] = recipeID end
    local listed = {}
    for _, recipeID in ipairs(candidates) do listed[recipeID] = true end
    local function vendorSold(itemID) return ctx.vendorBuy[itemID] end
    for _, recipeID in ipairs(ns.RecipeIndex.FromVendorGoods(vendorSold, filter)) do
        if not listed[recipeID] then
            candidates[#candidates + 1] = recipeID
            vendorOnly[recipeID] = true
        end
    end
    local results = {}
    for _, recipeID in ipairs(candidates) do
        local recipe = ns.RecipeIndex.Get(recipeID)
        local result = Evaluator.Evaluate(recipe, Evaluator.TrayCrafts(recipe, qty, vendorSold), ctx)
        result.known = ns.RecipeIndex.IsKnown(recipeID, "char")
        result.vendorOnly = vendorOnly[recipeID]
        result.ctx = ctx   -- the details pane re-evaluates other batch sizes against it (BatchAdvice)
        results[#results + 1] = result
    end
    return Evaluator.Rank(results), ctx
end

-- ---------------------------------------------------------------- Profession profits (1.0.0)

-- The context with only the tray's materials counted as yours (Justin, 2026-10-17): owned = the tray's
-- units per item (qty), so everything else is bought, even what's in the bags or bank. Reagents are bought
-- as the recipe lists them, from a vendor or the AH: no make-or-buy, so the Buy bar buys what the slots
-- show (Justin found "Craft" confusing there). makeFor keeps the recipes you know for the slots' hint
-- (Evaluator.MakeHint). The other tables are shared; trayOnly tells the details pane.
function Evaluator.TrayContext(ctx, qty)
    local out = {}
    for k, v in pairs(ctx) do out[k] = v end
    out.owned, out.trayOnly = qty, true
    out.recipeFor, out.makeFor = {}, ctx.recipeFor
    return out
end

-- What crafting qty units through recipe (a recipeFor entry) takes: the crafts, and the recipe's own
-- reagents for them.
local function Inputs(recipe, qty)
    local crafts = math.ceil(qty / recipe.yield)
    local inputs = {}
    for i = 1, #recipe.reagents, 2 do
        inputs[#inputs + 1] = { itemID = recipe.reagents[i], qty = recipe.reagents[i + 1] * crafts }
    end
    return crafts, inputs
end

-- A reagent line made with one of your recipes (source "craft"): { recipeID, crafts, inputs = { { itemID,
-- qty } } }, or nil.
function Evaluator.MadeFrom(line, ctx)
    local recipe = line.source == "craft" and ctx.recipeFor[line.itemID]
    if not recipe then return nil end
    local crafts, inputs = Inputs(recipe, line.rest)
    return { recipeID = recipe.recipeID, crafts = crafts, inputs = inputs }
end

-- Where reagents are bought as listed (TrayContext): a recipe you know that makes the line's units for less
-- than buying them, or makes one nobody sells. { cost, recipeID, crafts, inputs, saves } (saves: nil when it
-- can't be bought), or nil.
function Evaluator.MakeHint(line, ctx)
    local recipe = ctx.makeFor and line.rest > 0 and ctx.makeFor[line.itemID]
    if not recipe then return nil end
    local cost, source = Econ.Acquire(line.itemID, line.rest,
        { vendorBuy = ctx.vendorBuy, ladder = ctx.ladder, recipeFor = ctx.makeFor })
    if source ~= "craft" then return nil end
    local crafts, inputs = Inputs(recipe, line.rest)
    return { cost = cost, recipeID = recipe.recipeID, crafts = crafts, inputs = inputs,
             saves = line.source and line.buyCost - cost or nil }
end

-- The same recipe at another batch size, on the context it came from, keeping what its view set (the Buy
-- bar's Crafts box). r: a result with r.ctx.
function Evaluator.Reevaluate(r, crafts)
    local out = Evaluator.Evaluate(r.recipe, crafts, r.ctx)
    out.ctx, out.view, out.known, out.vendorOnly = r.ctx, r.view, r.known, r.vendorOnly
    return out
end

-- What a result still needs, line by line (the Buy bar): ah and vendor = { { itemID, qty, cost } } with
-- their totals ahCost and vendorCost; short = { { itemID, qty, available } } with no source (available:
-- what's listed when there isn't enough); tray = { { itemID, qty } }, the units the tray covers.
function Evaluator.ShoppingList(r)
    local list = { ah = {}, vendor = {}, short = {}, tray = {}, ahCost = 0, vendorCost = 0 }
    local available = {}
    for _, w in ipairs(r.warnings) do
        if w[1] == "cantFill" then available[w[2]] = w[3] end
    end
    for _, line in ipairs(r.lines) do
        if line.owned > 0 then list.tray[#list.tray + 1] = { itemID = line.itemID, qty = line.owned } end
        if line.rest > 0 then
            local entry = { itemID = line.itemID, qty = line.rest, cost = line.buyCost }
            if line.source == "ah" then
                list.ah[#list.ah + 1] = entry
                list.ahCost = list.ahCost + line.buyCost
            elseif line.source == "vendor" then
                list.vendor[#list.vendor + 1] = entry
                list.vendorCost = list.vendorCost + line.buyCost
            elseif not line.source then
                list.short[#list.short + 1] = { itemID = line.itemID, qty = line.rest, available = available[line.itemID] }
            end
        end
    end
    return list
end

-- The Buy bar's Best: the best batch (BatchAdvice: the reagents and the market), lowered to what money can buy
-- (what's bought, not what the tray holds), at least 1. Returns crafts, and true when money set it; nil when
-- no batch can be priced.
function Evaluator.AffordableBatch(r, money)
    r.batch = r.batch or Evaluator.BatchAdvice(r.recipe, r.crafts, r.ctx)
    local size = r.batch.size
    if not size then return nil end
    local function spend(n)
        local total = 0
        for _, line in ipairs(Evaluator.Evaluate(r.recipe, n, r.ctx).lines) do total = total + line.buyCost end
        return total
    end
    if spend(size) <= money then return size, false end
    local lo, hi = 0, size   -- lo crafts are affordable (0: none), hi aren't
    while hi - lo > 1 do
        local mid = math.floor((lo + hi) / 2)
        if spend(mid) <= money then lo = mid else hi = mid end
    end
    return math.max(1, lo), true
end

-- The Profession profits view: every recipe on the filter's professions (RecipeIndex.InProfessions),
-- evaluated on the tray-only context for the crafts the tray allows (1 for a recipe using none of its
-- reagents), ranked; the context; and the milliseconds it took.
function Evaluator.ForProfessions(tray, filter)
    local started = debugprofilestop()
    local _, qty = TrayQty(tray)
    local ctx = Evaluator.TrayContext(Evaluator.LiveContext(), qty)
    local function vendorSold(itemID) return ctx.vendorBuy[itemID] end
    local results = {}
    for _, recipeID in ipairs(ns.RecipeIndex.InProfessions(filter)) do
        local recipe = ns.RecipeIndex.Get(recipeID)
        local r = Evaluator.Evaluate(recipe, Evaluator.TrayCrafts(recipe, qty, vendorSold), ctx)
        r.view, r.ctx = "professions", ctx
        r.known = ns.RecipeIndex.IsKnown(recipeID, "char")
        local vendorOnly = true
        for _, g in ipairs(recipe.reagents) do
            if not vendorSold(g.itemID) then
                vendorOnly = false
                break
            end
        end
        r.vendorOnly = vendorOnly or nil
        results[#results + 1] = r
    end
    return Evaluator.Rank(results), ctx, debugprofilestop() - started
end

-- ---------------------------------------------------------------- vendor crafts (M4 pass 3)

-- The context with the Auction House taken out (no AH prices, ladders or price data): a recipe
-- evaluated on it counts vendor prices only, with owned reagents at what a vendor pays. The other
-- tables are shared.
function Evaluator.VendorContext(ctx)
    local out = {}
    for k, v in pairs(ctx) do out[k] = v end
    out.sellPrice, out.ladder, out.priceInfo = {}, {}, {}
    return out
end

-- The crafts your bags allow when every reagent a vendor (or a recipe from vendor goods) can't supply
-- must be owned: the smallest owned / count over those reagents; 1 when a vendor supplies them all.
function Evaluator.VendorBatch(recipe, ctx)
    local crafts
    for _, g in ipairs(recipe.reagents) do
        if not Econ.Acquire(g.itemID, g.count, ctx) then
            local n = math.floor((ctx.owned[g.itemID] or 0) / g.count)
            crafts = crafts and math.min(crafts, n) or n
        end
    end
    return crafts or 1
end

-- One vendor craft on the vendor-only context ctx, for the crafts your bags allow; nil when a reagent
-- is missing or it doesn't profit. rawAH: what the owned reagents would fetch at their AH-aware value
-- (the full context); rawBetter when that beats crafting (the vendor sale minus what you'd buy).
function Evaluator.VendorCraft(recipe, ctx, full)
    local crafts = Evaluator.VendorBatch(recipe, ctx)
    if crafts < 1 then return nil end
    local r = Evaluator.Evaluate(recipe, crafts, ctx)
    if not r.profit or r.profit <= 0 then return nil end
    local raw, bought = 0, 0
    for _, line in ipairs(r.lines) do
        bought = bought + line.buyCost
        if line.owned > 0 then raw = raw + line.owned * (Liquidation(full, line.itemID, line.need) or 0) end
    end
    r.view, r.ctx, r.rawAH = "vendor", ctx, raw
    r.rawBetter = raw > r.best - bought + 0.5
    return r
end

-- The Vendor crafts view: every recipe this character knows that profits on vendor prices alone
-- (certain profit, no AH risk), ranked; and the vendor-only context.
function Evaluator.VendorCrafts()
    local full = Evaluator.LiveContext()
    local ctx = Evaluator.VendorContext(full)
    local results = {}
    for _, recipeID in ipairs(ns.RecipeIndex.Known()) do
        local r = Evaluator.VendorCraft(ns.RecipeIndex.Get(recipeID), ctx, full)
        if r then
            r.known = true
            results[#results + 1] = r
        end
    end
    return Evaluator.Rank(results), ctx
end

-- What /bf eval saw and decided, for `cli.py econ check` to replay in Python: the tray, the
-- settings, every context value looked up (false = unknown), and the ranked results.
local SNAPSHOT_MAX = 300

local function RawCopy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end   -- the lazy tables' cached entries only
    return out
end

function Evaluator.Snapshot(tray, results, ctx)
    if not ns.db or ns.readOnlyDB then return end
    local snap = {
        t = GetServerTime(), build = select(2, GetBuildInfo()), dataBuild = ns.RecipesBuild,
        settings = RawCopy(ctx.settings), tray = {}, ctx = {}, results = {},
    }
    for _, e in ipairs(tray) do snap.tray[#snap.tray + 1] = { itemID = e.itemID, qty = e.qty } end
    for _, name in ipairs({ "vendorBuy", "vendorSell", "sellPrice", "ladder", "owned", "deposit", "commodity",
                            "saleChance", "priceInfo", "recipeFor" }) do
        snap.ctx[name] = RawCopy(ctx[name])
    end
    for i = 1, math.min(SNAPSHOT_MAX, #results) do
        local r = results[i]
        local reagents, sources = {}, {}
        for _, g in ipairs(r.recipe.reagents) do
            reagents[#reagents + 1] = g.itemID
            reagents[#reagents + 1] = g.count
        end
        for _, line in ipairs(r.lines) do sources[#sources + 1] = line.source or "-" end
        snap.results[i] = {
            recipeID = r.recipe.recipeID, output = r.recipe.output, count = r.recipe.count, bop = r.recipe.bop,
            reagents = reagents, crafts = r.crafts, cogs = r.cogs, vendorExit = r.vendorExit, ahExit = r.ahExit,
            best = r.best, bestSource = r.bestSource, profit = r.profit, roi = r.roi, valueAdded = r.valueAdded,
            grade = r.grade, recommended = r.recommended, reasons = r.reasons, sources = sources,
        }
    end
    ns.db.diag.eval = snap
end

-- ---------------------------------------------------------------- wording

local REASON_TEXT = {
    noReagentPrice = "a reagent has no price",
    noExit = "no price for the result",
    loss = "it loses money",
    roiUnderMargin = "ROI under your margin of safety",
    underMinProfit = "under the minimum profit per craft",
    thinData = "price data too thin",
    sellRaw = "selling the materials raw is as good",
}

function Evaluator.ReasonText(key)
    return L[REASON_TEXT[key] or key]
end

local function Pct(x)
    return string.format("%d%%", math.floor(x * 100 + 0.5))
end

-- One sentence: the action, the number, the reason (risk-and-recommendation.md "Wording").
-- name: the output's link or name.
function Evaluator.Advice(r, name)
    local M = ns.Money.Format
    if r.recommended then
        local roi = r.roi and Pct(r.roi) or L["n/a"]   -- nothing spent; WoW's fonts have no infinity sign
        if r.bestSource == "ah" then
            local text = string.format(L["Craft %d x %s and sell on the AH: +%s (ROI %s, confidence %s)."],
                r.crafts, name, M(r.profit), roi, r.grade)
            if r.vendorExit then text = text .. " " .. string.format(L["A vendor pays %s."], M(r.vendorExit)) end
            return text
        end
        local text = string.format(L["Craft %d x %s and sell to a vendor: +%s (ROI %s)."], r.crafts, name, M(r.profit), roi)
        if r.underMargin then
            text = text .. " " .. string.format(L["The AH beats it by only %s, under your %s margin of safety."],
                Pct(r.ahExit / r.vendorExit - 1), Pct(ns.db.settings.margin))
        end
        return text
    end
    if r.profit and r.profit < 0 then
        return string.format(L["Don't craft %s: you'd lose %s per craft. Selling the materials gets %s."], name,
            M(-r.profit / r.crafts), M(r.liquidation))
    end
    for _, w in ipairs(r.warnings) do
        if w[1] == "cantFill" then
            return string.format(L["Only %d of %s listed; this batch needs %d."], w[3], ns.Items.Link(w[2]), w[4])
        end
    end
    local why = {}
    for _, key in ipairs(r.reasons) do why[#why + 1] = Evaluator.ReasonText(key) end
    return string.format(L["%s: not recommended (%s)."], name, table.concat(why, ", "))
end

-- /bf eval: the tray's best recipes in chat (until the results pane arrives in M3 pass 2).
local EVAL_LINES = 5

function Evaluator.PrintTray()
    local entries = ns.Tray.Entries()
    if #entries == 0 then
        ns.Print(L["The tray is empty: drag reagents into it, or use Load from bags."])
        return
    end
    local results, ctx = Evaluator.ForTray(entries, { confirmed = true })
    if #results == 0 then
        ns.Print(L["No confirmed recipe uses these reagents."])
        return
    end
    Evaluator.Snapshot(entries, results, ctx)
    local ids = {}
    for i = 1, math.min(EVAL_LINES, #results) do
        ids[#ids + 1] = results[i].recipe.output
        for _, line in ipairs(results[i].lines) do ids[#ids + 1] = line.itemID end
    end
    ns.Items.Load(ids, function()
        local M = ns.Money.Format
        local recommended = 0
        for _, r in ipairs(results) do
            if r.recommended then recommended = recommended + 1 end
        end
        ns.Print(string.format(L["%d recipes use your tray reagents; %d recommended."], #results, recommended))
        for i = 1, math.min(EVAL_LINES, #results) do
            local r = results[i]
            local exit = r.best and ((r.bestSource == "ah" and L["AH"] or L["vendor"]) .. " " .. M(r.best)) or L["no price"]
            local profit = r.profit and ((r.profit >= 0 and "+" or "") .. M(r.profit)) or "?"
            local crafts = r.recipe.count > 1 and string.format(L[" (%d crafts)"], r.crafts) or ""
            local text = string.format(L["%d. %s x%d%s%s: cost %s, %s, profit %s, ROI %s, grade %s"], i,
                ns.Items.Link(r.recipe.output), r.units, crafts, r.known and (" " .. L["(known)"]) or "", M(r.cogs), exit,
                profit, r.roi and Pct(r.roi) or L["n/a"], r.grade)
            if not r.recommended then
                local why = {}
                for _, key in ipairs(r.reasons) do why[#why + 1] = Evaluator.ReasonText(key) end
                text = text .. " - " .. table.concat(why, ", ")
            end
            ns.Print(text)
        end
        ns.Print(Evaluator.Advice(results[1], ns.Items.Link(results[1].recipe.output)))
    end)
end

-- ---------------------------------------------------------------- self test

-- CRAFT-1, CRAFT-2, VENDOR-1 from crafting-economics.md on mock contexts.
function Evaluator.SelfTest(report)
    local passed, failed = 0, 0
    local function check(name, ok, detail)
        if ok then passed = passed + 1 else failed = failed + 1 end
        report(name, ok, detail)
    end
    local function near(a, b) return type(a) == "number" and math.abs(a - b) < 0.01 end
    local settings = { cut = 0.05, saleChance = 0.5, margin = 0.2, minProfit = 0, minGrade = "D", ownedPolicy = "opportunity" }
    local function bolts(deposit)
        return {
            settings = settings, vendorBuy = {}, recipeFor = {}, priceInfo = {},
            vendorSell = { [2589] = 13, [2996] = 40 },
            sellPrice = { [2589] = 950, [2996] = 2900 },
            ladder = { [2589] = { 950, 20, 1000, 40, 1100, 100 } },
            owned = { [2589] = 6 },
            deposit = { [2996] = deposit },
        }
    end
    local bolt = { recipeID = 2963, output = 2996, count = 1, bop = false, reagents = { { itemID = 2589, count = 2 } } }
    local r = Evaluator.Evaluate(bolt, 10, bolts(0))
    check("CRAFT-1", near(r.cogs, 18715) and near(r.ahExit, 27550) and r.vendorExit == 400 and near(r.profit, 8835)
        and near(r.roi, 0.47208) and near(r.valueAdded, 9500) and r.bestSource == "ah",
        string.format("COGS %s, AH %s, vendor %s, profit %s, ROI %s, value added %s", tostring(r.cogs), tostring(r.ahExit),
            tostring(r.vendorExit), tostring(r.profit), tostring(r.roi), tostring(r.valueAdded)))
    r = Evaluator.Evaluate(bolt, 10, bolts(60))
    check("CRAFT-2", near(r.ahExit, 26950) and near(r.profit, 8235) and near(r.roi, 0.44002),
        string.format("AH %s, profit %s, ROI %s", tostring(r.ahExit), tostring(r.profit), tostring(r.roi)))
    local bronze = { recipeID = 2659, output = 2841, count = 2, bop = false,
                     reagents = { { itemID = 2840, count = 1 }, { itemID = 3576, count = 1 } } }
    r = Evaluator.Evaluate(bronze, 1, {
        settings = settings, vendorBuy = {}, recipeFor = {}, priceInfo = {}, sellPrice = {}, ladder = {}, deposit = {},
        vendorSell = { [2840] = 10, [3576] = 35, [2841] = 50 }, owned = { [2840] = 1, [3576] = 1 },
    })
    check("VENDOR-1", near(r.cogs, 45) and r.vendorExit == 100 and near(r.profit, 55) and near(r.roi, 1.22222)
        and r.bestSource == "vendor",
        string.format("COGS %s, vendor %s, profit %s, ROI %s", tostring(r.cogs), tostring(r.vendorExit), tostring(r.profit),
            tostring(r.roi)))

    -- Vendor crafts (M4 pass 3): the AH taken out, the batch your bags allow, and owned materials that
    -- would fetch more on the AH (the VENDOR-CRAFT scenario's numbers).
    local full = {
        settings = settings, vendorBuy = { [52] = 25 }, vendorSell = { [50] = 300, [51] = 40 }, owned = { [51] = 6 },
        sellPrice = { [51] = 900, [50] = 2000 }, ladder = { [51] = { 900, 50 } }, priceInfo = {}, recipeFor = {},
        deposit = {},
    }
    local vctx = Evaluator.VendorContext(full)
    check("VEND-CTX", next(vctx.sellPrice) == nil and next(vctx.ladder) == nil and vctx.vendorBuy == full.vendorBuy
        and full.sellPrice[51] == 900, "the AH is taken out of a copy; everything else is shared")
    local craft = { recipeID = 5, output = 50, count = 1, bop = false,
                    reagents = { { itemID = 51, count = 2 }, { itemID = 52, count = 1 } } }
    check("VEND-BATCH", Evaluator.VendorBatch(craft, vctx) == 3, "6 owned at 2 a craft; the vendor reagent doesn't limit")
    local vr = Evaluator.VendorCraft(craft, vctx, full)
    check("VEND-RAW", vr ~= nil and near(vr.profit, 585) and near(vr.rawAH, 5130) and vr.rawBetter == true,
        string.format("profit %s at vendor prices; the 6 owned would fetch %s on the AH", tostring(vr and vr.profit),
            tostring(vr and vr.rawAH)))

    -- Profession profits (1.0.0): only the tray counts as yours, and the tray sets the batch.
    local live = bolts(0)
    local empty = Evaluator.Evaluate(bolt, 10, Evaluator.TrayContext(live, {}))
    local trayed = Evaluator.Evaluate(bolt, 10, Evaluator.TrayContext(live, { [2589] = 6 }))
    check("TRAY-CTX", empty.lines[1].owned == 0 and near(empty.cogs, 19000) and trayed.lines[1].owned == 6
        and near(trayed.cogs, 18715) and live.owned[2589] == 6,
        string.format("6 in the bags but none in the tray: all 20 bought (%s); 6 in the tray: CRAFT-1's %s",
            tostring(empty.cogs), tostring(trayed.cogs)))
    local function vendorSold(itemID) return itemID == 52 end
    local T = Evaluator.TrayCrafts
    check("TRAY-CRAFTS", T(craft, { [51] = 7, [52] = 1 }, vendorSold) == 3 and T(craft, { [52] = 4 }, vendorSold) == 4
        and T(craft, {}, vendorSold) == 1 and T(craft, { [51] = 1 }, vendorSold) == 1,
        "7 of a 2-a-craft reagent: 3 (the vendor one doesn't cap); vendor goods only: 4; nothing: 1; too few: 1")

    -- Reagents are bought as listed there; a recipe you know that makes one for less is a hint. Item 60: 4 at
    -- 10 on the AH (40), or made from 3 of item 61 each at a vendor's 2 (24); item 63: nobody sells it, made 2
    -- at a time from 1 of item 61.
    local makes = {
        settings = settings, vendorBuy = { [61] = 2 }, vendorSell = {}, sellPrice = {}, priceInfo = {}, deposit = {},
        owned = {}, ladder = { [60] = { 10, 100 } },
        recipeFor = { [60] = { yield = 1, reagents = { 61, 3 }, recipeID = 7 }, [63] = { yield = 2, reagents = { 61, 1 }, recipeID = 9 } },
    }
    local kit = { recipeID = 8, output = 62, count = 1, bop = false,
                  reagents = { { itemID = 60, count = 4 }, { itemID = 63, count = 3 } } }
    local made = Evaluator.Evaluate(kit, 1, makes)
    local tctx = Evaluator.TrayContext(makes, {})
    local bought = Evaluator.Evaluate(kit, 1, tctx)
    local hint, none = Evaluator.MakeHint(bought.lines[1], tctx), Evaluator.MakeHint(bought.lines[2], tctx)
    check("TRAY-BUY", made.lines[1].source == "craft" and near(made.cogs, 28) and bought.lines[1].source == "ah"
        and near(bought.lines[1].buyCost, 40) and bought.lines[2].source == nil and hint ~= nil and near(hint.cost, 24)
        and near(hint.saves, 16) and hint.inputs[1].itemID == 61 and hint.inputs[1].qty == 12 and none ~= nil
        and near(none.cost, 4) and none.saves == nil and none.crafts == 2,
        string.format("bought from the AH for %s, the hint makes them for %s; one nobody sells: made for %s",
            tostring(bought.lines[1].buyCost), tostring(hint and hint.cost), tostring(none and none.cost)))

    -- The Buy bar: another batch on the same context, what's left to buy, and Best within your gold
    -- (20 Linen at 950, then 40 at 1000, 100 at 1100: 10 bolts cost 19,000; the best batch is all 80).
    local one = Evaluator.Evaluate(bolt, 1, Evaluator.TrayContext(live, {}))
    one.ctx, one.view, one.known = Evaluator.TrayContext(live, {}), "professions", true
    local five = Evaluator.Reevaluate(one, 5)
    check("CRAFTS", five.crafts == 5 and five.units == 5 and five.lines[1].need == 10 and near(five.cogs, 9500)
        and five.ctx == one.ctx and five.view == "professions" and five.known == true,
        string.format("5 crafts: %s Linen for %s, on the same context", tostring(five.lines[1].need), tostring(five.cogs)))
    local shop = Evaluator.ShoppingList({
        lines = {
            { itemID = 1, need = 4, owned = 2, rest = 2, source = "ah", buyCost = 20 },
            { itemID = 2, need = 3, owned = 0, rest = 3, source = "vendor", buyCost = 30 },
            { itemID = 3, need = 5, owned = 0, rest = 5, buyCost = 0 },
            { itemID = 4, need = 2, owned = 2, rest = 0, buyCost = 0 },
        },
        warnings = { { "cantFill", 3, 1, 5 } },
    })
    check("SHOP-LIST", #shop.ah == 1 and shop.ah[1].qty == 2 and shop.ahCost == 20 and #shop.vendor == 1
        and shop.vendorCost == 30 and #shop.short == 1 and shop.short[1].qty == 5 and shop.short[1].available == 1
        and #shop.tray == 2 and shop.tray[2].itemID == 4,
        string.format("AH %d line(s), vendor %d, short %d, tray %d", #shop.ah, #shop.vendor, #shop.short, #shop.tray))
    local all, capped = Evaluator.AffordableBatch(one, 1e9), Evaluator.AffordableBatch(one, 19000)
    local under, underGold = Evaluator.AffordableBatch(one, 18999)
    check("BEST-GOLD", all == 80 and capped == 10 and under == 9 and underGold == true,
        string.format("any gold: %s; 19,000: %s; 18,999: %s", tostring(all), tostring(capped), tostring(under)))

    -- Branch scenarios with results from the Python reference (Economics/EvaluatorVectors.lua,
    -- generated by `cli.py econ vectors`): every field must match.
    for _, v in ipairs(ns.EvaluatorVectors or {}) do
        r = Evaluator.Evaluate(v.recipe, v.crafts, v.ctx)
        local e, problems = v.expect, {}
        local function num(field, tolerance)
            local a, b = r[field], e[field]
            if (a == nil) ~= (b == nil) or (a ~= nil and math.abs(a - b) > tolerance) then
                problems[#problems + 1] = string.format("%s %s, expected %s", field, tostring(a), tostring(b))
            end
        end
        local function same(field, a, b)
            if a ~= b then problems[#problems + 1] = string.format("%s %s, expected %s", field, tostring(a), tostring(b)) end
        end
        for _, field in ipairs({ "cogs", "vendorExit", "ahExit", "best", "profit", "valueAdded" }) do num(field, 0.01) end
        num("roi", 1e-6)
        same("bestSource", r.bestSource, e.bestSource)
        same("grade", r.grade, e.grade)
        same("recommended", r.recommended, e.recommended)
        same("reasons", table.concat(r.reasons, ","), e.reasons)
        local sources, warnings = {}, {}
        for _, line in ipairs(r.lines) do sources[#sources + 1] = line.source or "-" end
        for _, w in ipairs(r.warnings) do warnings[#warnings + 1] = w[1] end
        same("sources", table.concat(sources, ","), e.sources)
        same("warnings", table.concat(warnings, ","), e.warnings)
        if e.batchLimit then
            local advice = Evaluator.BatchAdvice(v.recipe, v.crafts, v.ctx)
            same("batch best", advice.best, e.batchBest)
            same("batch cap", advice.cap, e.batchCap)
            same("batch size", advice.size, e.batchSize)
            same("batch limit", advice.limit, e.batchLimit)
        end
        check("VEC " .. v.name, #problems == 0, #problems == 0 and "matches the Python reference" or table.concat(problems, "; "))
    end
    return passed, failed
end
