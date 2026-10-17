local addonName, ns = ...

-- Crafting evaluation (wowf-economics crafting-economics.md and risk-and-recommendation.md). For one
-- recipe and N crafts:
-- - what the reagents cost: owned stock first, valued per the owned-materials policy, then the rest
--   from the cheapest of vendor, AH ladder or a recipe this character knows (make-or-buy, depth 3);
-- - what the output fetches: the vendor, or the AH after the cut and the expected deposit loss; the
--   AH is chosen only when it beats the vendor by the margin of safety;
-- - profit, ROI, value added over selling the inputs raw, and a confidence grade;
-- - whether to recommend it, and the reasons when not.
-- Evaluate() reads only its context table, so /bf selftest runs the reference vectors on mock
-- contexts. LiveContext() builds the real one from PriceDB, Merchant, the bags and known recipes.
-- Context tables (indexed by itemID): vendorBuy, vendorSell, sellPrice (conservative AH unit price),
-- ladder, recipeFor ({ yield, reagents = { id, qty, ... } }), owned, deposit, priceInfo ({ age,
-- days, observations, cv, listed }); plus settings.

local L = ns.L
local Econ = ns.Econ
local Evaluator = {}
ns.Evaluator = Evaluator

local GRADES = { "A", "B", "C", "D" }
local STALE = 48 * 3600     -- older AH data: fair value instead of the latest scan

local function Grade(ctx, itemID, need)
    local info = ctx.priceInfo[itemID]
    if not info then return "D" end
    return Econ.Grade(info.age, info.days, info.observations, info.cv, info.listed, need)
end

-- Per-unit liquidation value (the better of vendor and AH net), and whether the AH set it.
local function Liquidation(ctx, itemID)
    local s = ctx.settings
    local vendor = ctx.vendorSell[itemID] or nil
    local ahNet = Econ.AHNet(ctx.sellPrice[itemID] or nil, s.cut, ctx.deposit[itemID] or 0, s.saleChance)
    return Econ.Liquidation(vendor, ahNet), ahNet ~= nil and (not vendor or ahNet > vendor)
end

-- recipe: { recipeID, output, count (yield per craft), bop, reagents = { { itemID, count } } }.
function Evaluator.Evaluate(recipe, crafts, ctx)
    local s = ctx.settings
    local r = { recipe = recipe, crafts = crafts, units = recipe.count * crafts, lines = {}, warnings = {}, reasons = {} }
    local cogs, liquidation, complete, worst, ownedAny = 0, 0, true, 1, false
    local function note(grade)
        local rank = Econ.GRADE_RANK[grade]
        if rank > worst then worst = rank end
    end

    for _, g in ipairs(recipe.reagents) do
        local itemID, need = g.itemID, g.count * crafts
        local line = { itemID = itemID, need = need, owned = 0, ownedCost = 0, buyCost = 0 }
        local unitLiq, fromAH = Liquidation(ctx, itemID)
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
                if unit and fromAH then note(Grade(ctx, itemID, nil)) end
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
                if source == "ah" then note(Grade(ctx, itemID, rest)) end
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
        local unit = Econ.AHNet(ctx.sellPrice[recipe.output] or nil, s.cut, ctx.deposit[recipe.output] or 0, s.saleChance)
        if unit then
            r.ahUnit = unit
            r.ahExit = unit * r.units
        end
    end
    if r.ahExit and (not r.vendorExit or r.ahExit >= r.vendorExit * (1 + s.margin)) then
        r.best, r.bestSource = r.ahExit, "ah"
        note(Grade(ctx, recipe.output, nil))
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

-- Context over this character's data; lookups are cached for one evaluation run.
function Evaluator.LiveContext()
    local today = ns.PriceDB.Today()
    local ctx = { settings = ns.db.settings }
    ctx.vendorBuy = Lazy(function(itemID) return (ns.Merchant.Get(itemID)) end)
    ctx.vendorSell = Lazy(function(itemID)
        local sell = ns.ItemSellPrice and ns.ItemSellPrice[itemID]
        if not sell then sell = select(11, C_Item.GetItemInfo(itemID)) end
        if type(sell) == "number" and sell > 0 then return sell end
        return nil
    end)
    -- Selling: the lower of market value and min buyout; the fair value once the scan is stale.
    ctx.sellPrice = Lazy(function(itemID)
        local row, age = Row(itemID)
        if not row then return nil end
        if age <= STALE then return math.min(row.mv, row.min) end
        local fair = Econ.FairValue((ns.PriceDB.History(row)), today, 3, ns.db.settings.historyDays)
        return fair and math.min(fair, row.min) or nil
    end)
    -- Buying: the latest ladder; once stale, one level at the fair value (the grade says so).
    ctx.ladder = Lazy(function(itemID)
        local row, age = Row(itemID)
        if not row or not row.ladder then return nil end
        if age <= STALE then return ns.PriceDB.UnpackLadder(row.ladder) end
        local fair = Econ.FairValue((ns.PriceDB.History(row)), today, 3, ns.db.settings.historyDays)
        return fair and { fair, row.q or 0 } or nil
    end)
    ctx.priceInfo = Lazy(function(itemID)
        local row, age = Row(itemID)
        if not row then return nil end
        local history, days, observations = ns.PriceDB.History(row)
        local _, cv = Econ.Volatility(history, today, ns.db.settings.historyDays)
        return { age = age, days = days, observations = observations, cv = days > 1 and cv or nil, listed = row.q or 0 }
    end)
    ctx.owned = Lazy(function(itemID) return C_Item.GetItemCount(itemID, true) end)
    ctx.deposit = Lazy(function() return 0 end)   -- unmeasured until M4 caches deposits at the auctioneer
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

-- Every recipe that uses the tray's reagents, evaluated for the crafts the tray quantities allow
-- (at least 1), ranked. tray: { { itemID, qty } }. filter: RecipeIndex filter.
function Evaluator.ForTray(tray, filter)
    local ids, qty = {}, {}
    for _, e in ipairs(tray) do
        if not qty[e.itemID] then ids[#ids + 1] = e.itemID end
        qty[e.itemID] = (qty[e.itemID] or 0) + e.qty
    end
    local ctx = Evaluator.LiveContext()
    local results = {}
    for _, recipeID in ipairs(ns.RecipeIndex.UsingAny(ids, filter)) do
        local recipe = ns.RecipeIndex.Get(recipeID)
        local crafts
        for _, g in ipairs(recipe.reagents) do
            if qty[g.itemID] then
                local n = math.floor(qty[g.itemID] / g.count)
                crafts = crafts and math.min(crafts, n) or n
            end
        end
        local result = Evaluator.Evaluate(recipe, math.max(1, crafts or 1), ctx)
        result.known = ns.RecipeIndex.IsKnown(recipeID, "char")
        results[#results + 1] = result
    end
    return Evaluator.Rank(results)
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
    local results = Evaluator.ForTray(entries, { confirmed = true })
    if #results == 0 then
        ns.Print(L["No confirmed recipe uses these reagents."])
        return
    end
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
    return passed, failed
end
