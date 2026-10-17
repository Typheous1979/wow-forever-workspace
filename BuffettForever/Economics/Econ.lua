local addonName, ns = ...

-- Pure pricing functions from the wowf-economics references (price-estimation.md,
-- crafting-economics.md, risk-and-recommendation.md). No game state in here: numbers in, numbers
-- out, so /bf selftest can check them against the reference test vectors.
-- Listings and ladders are flat { unitPrice1, qty1, unitPrice2, qty2, ... } in copper per unit.

local Econ = ns.Econ or {}
ns.Econ = Econ

local LADDER_LEVELS = 8      -- price levels kept from each scan...
local LADDER_DEPTH = 100     -- ...or more, until they cover this many units
local LADDER_MAX = 16        -- hard cap on levels

local function WeightedStats(listings, set)
    local w, s = 0, 0
    for _, i in ipairs(set) do
        w = w + listings[2 * i]
        s = s + listings[2 * i - 1] * listings[2 * i]
    end
    local mean = s / w
    local v = 0
    for _, i in ipairs(set) do
        local d = listings[2 * i - 1] - mean
        v = v + d * d * listings[2 * i]
    end
    return mean, math.sqrt(v / w)
end

-- Lower-quantile trimmed mean (price-estimation.md "Market value").
-- Returns marketValue, minBuyout, totalQuantity, auctionCount; nil for no listings.
function Econ.MarketValue(listings)
    local n = #listings / 2
    if n < 1 then return nil end
    local order = {}
    for i = 1, n do order[i] = i end
    table.sort(order, function(a, b) return listings[2 * a - 1] < listings[2 * b - 1] end)
    local total = 0
    for i = 1, n do total = total + listings[2 * i] end
    local lowCap, highCap = total * 0.15, total * 0.30
    local window, cum, prev = {}, 0, nil
    for _, i in ipairs(order) do
        local p, q = listings[2 * i - 1], listings[2 * i]
        if cum >= lowCap and (cum >= highCap or (prev and p > prev * 1.2)) then break end
        window[#window + 1] = i
        cum = cum + q
        prev = p
    end
    local mean, sd = WeightedStats(listings, window)
    local kept = {}
    for _, i in ipairs(window) do
        if math.abs(listings[2 * i - 1] - mean) <= 2 * sd then kept[#kept + 1] = i end
    end
    if #kept > 0 then mean = WeightedStats(listings, kept) end
    return mean, listings[2 * order[1] - 1], total, n
end

-- The price ladder (price-estimation.md "Cost to buy Q units"): equal prices merged, cheapest
-- first, LADDER_LEVELS levels or more until LADDER_DEPTH units are covered (at most LADDER_MAX).
-- Returns a flat { price1, qty1, price2, qty2, ... }.
function Econ.BuildLadder(listings)
    local qtyAt, prices = {}, {}
    for i = 1, #listings, 2 do
        local p, q = listings[i], listings[i + 1]
        if qtyAt[p] then
            qtyAt[p] = qtyAt[p] + q
        else
            qtyAt[p] = q
            prices[#prices + 1] = p
        end
    end
    table.sort(prices)
    local ladder, covered = {}, 0
    for i, p in ipairs(prices) do
        if i > LADDER_MAX or (i > LADDER_LEVELS and covered >= LADDER_DEPTH) then break end
        ladder[#ladder + 1] = p
        ladder[#ladder + 1] = qtyAt[p]
        covered = covered + qtyAt[p]
    end
    return ladder
end

-- Cost to buy qty units by walking the ladder (price-estimation.md). Returns cost, filled, unitsAvailable.
function Econ.CostToBuy(ladder, qty)
    local need, cost = qty, 0
    for i = 1, #ladder, 2 do
        local take = math.min(need, ladder[i + 1])
        cost = cost + take * ladder[i]
        need = need - take
        if need <= 0 then return cost, true, qty end
    end
    return cost, false, qty - need
end

-- Decay-weighted fair value of daily values { [day] = value } (price-estimation.md); nil = unknown.
function Econ.FairValue(history, today, halfLife, window)
    halfLife, window = halfLife or 3, window or 14
    local num, den = 0, 0
    for day, v in pairs(history) do
        local age = today - day
        if age >= 0 and age < window then
            local w = 0.5 ^ (age / halfLife)
            num = num + w * v
            den = den + w
        end
    end
    if den == 0 then return nil end
    return num / den
end

-- What one unit nets on the AH (crafting-economics.md): price after the cut, minus the deposits
-- expected to be lost on listings that don't sell (deposit x (1 - p) / p).
function Econ.AHNet(price, cut, deposit, p)
    if not price then return nil end
    deposit, p = deposit or 0, p or 0.5
    return price * (1 - (cut or 0.05)) - deposit * (1 - p) / p
end

-- Liquidation value of one unit you own: the better of selling it to a vendor or on the AH.
function Econ.Liquidation(vendorSell, ahNet)
    if ahNet and vendorSell then return math.max(vendorSell, ahNet) end
    return ahNet or vendorSell
end

-- ROI is undefined when nothing was spent (everything owned and valued free): nil, rank by profit.
function Econ.ROI(profit, cogs)
    if not profit or not cogs or cogs <= 0 then return nil end
    return profit / cogs
end

-- Cheapest way to obtain qty of itemID (crafting-economics.md "Make-or-buy"). ctx supplies tables
-- vendorBuy[id], ladder[id] and recipeFor[id] = { yield, reagents = { id, qty, ... } }.
-- Returns cost, source ("vendor", "ah", "craft"), or nil when no source is known.
function Econ.Acquire(itemID, qty, ctx, depth, visiting)
    depth, visiting = depth or 0, visiting or {}
    local best, source
    local unit = ctx.vendorBuy[itemID]
    if unit then best, source = unit * qty, "vendor" end
    local ladder = ctx.ladder[itemID]
    if ladder then
        local cost, filled = Econ.CostToBuy(ladder, qty)
        if filled and (not best or cost < best) then best, source = cost, "ah" end
    end
    local recipe = ctx.recipeFor[itemID]
    if recipe and depth < 3 and not visiting[itemID] then
        visiting[itemID] = true
        local crafts = math.ceil(qty / recipe.yield)
        local cost = 0
        for i = 1, #recipe.reagents, 2 do
            local c = Econ.Acquire(recipe.reagents[i], recipe.reagents[i + 1] * crafts, ctx, depth + 1, visiting)
            if not c then
                cost = nil
                break
            end
            cost = cost + c
        end
        visiting[itemID] = nil
        if cost and (not best or cost < best) then best, source = cost, "craft" end
    end
    return best, source
end

-- Mean and coefficient of variation (sd / mean) of daily values { [day] = value } in the window.
function Econ.Volatility(history, today, window)
    window = window or 14
    local n, sum = 0, 0
    for day, v in pairs(history) do
        if today - day >= 0 and today - day < window then
            n, sum = n + 1, sum + v
        end
    end
    if n == 0 then return nil, nil end
    local mean = sum / n
    local var = 0
    for day, v in pairs(history) do
        if today - day >= 0 and today - day < window then var = var + (v - mean) ^ 2 end
    end
    if mean <= 0 then return mean, nil end
    return mean, math.sqrt(var / n) / mean
end

local GRADES = { "A", "B", "C", "D" }
Econ.GRADE_RANK = { A = 1, B = 2, C = 3, D = 4 }

-- Confidence grade of an AH price (risk-and-recommendation.md): the worst of age, days observed
-- (of 14; a single observation is D), volatility and depth. need nil = no depth test (an exit).
-- Also returns which test set the grade: "age", "single", "days", "volatile", "depth", "unlisted"
-- (the first one to reach the worst grade), or nil for A.
function Econ.Grade(ageSeconds, daysObserved, observations, cv, listed, need)
    local g, why = 1, nil
    local function worse(x, reason)
        if x > g then g, why = x, reason end
    end
    if not ageSeconds then return "D", "unlisted" end
    if ageSeconds >= 7 * 86400 then worse(4, "age") elseif ageSeconds >= 48 * 3600 then worse(3, "age")
    elseif ageSeconds >= 24 * 3600 then worse(2, "age") end
    if (observations or 0) <= 1 then worse(4, "single")
    elseif daysObserved >= 5 then worse(1, "days")
    elseif daysObserved >= 3 then worse(2, "days")
    else worse(3, "days") end
    if cv then
        if cv >= 0.60 then worse(4, "volatile") elseif cv >= 0.30 then worse(3, "volatile")
        elseif cv >= 0.15 then worse(2, "volatile") end
    end
    listed = listed or 0
    if need then
        if listed < need then worse(4, "depth") elseif listed < 2 * need then worse(2, "depth") end
    elseif listed <= 0 then
        worse(4, "unlisted")
    end
    return GRADES[g], why
end

-- Test vectors: MV-1..3 from price-estimation.md, plus ladder merging and depth.
-- report(name, ok, detail) is called for each case; returns passed, failed.
function Econ.SelfTest(report)
    local passed, failed = 0, 0
    local function check(name, ok, detail)
        if ok then passed = passed + 1 else failed = failed + 1 end
        report(name, ok, detail)
    end
    local function near(a, b) return type(a) == "number" and math.abs(a - b) < 0.01 end

    local cases = {
        { "MV-1", { 100, 5, 105, 5, 110, 10, 300, 20, 1000, 60 }, 106.25, 100, 100, 5 },
        { "MV-2", { 250, 3 }, 250, 250, 3, 1 },
        { "MV-3", { 1, 1, 500, 20, 510, 30, 520, 49 }, 506, 1, 100, 4 },
    }
    for _, c in ipairs(cases) do
        local mv, min, q, n = Econ.MarketValue(c[2])
        check(c[1], near(mv, c[3]) and min == c[4] and q == c[5] and n == c[6],
            string.format("market %s, min %s, qty %s, auctions %s", tostring(mv), tostring(min), tostring(q), tostring(n)))
    end
    check("MV-empty", Econ.MarketValue({}) == nil, "no listings -> nil")

    local merged = Econ.BuildLadder({ 105, 5, 100, 5, 100, 3, 110, 10 })
    check("LADDER-1", table.concat(merged, ",") == "100,8,105,5,110,10", table.concat(merged, ","))

    local deep = {}
    for i = 1, 20 do
        deep[#deep + 1] = 100 + i
        deep[#deep + 1] = 10
    end
    local ladder = Econ.BuildLadder(deep)
    check("LADDER-2", #ladder / 2 == 10, string.format("%d levels cover 100 units", #ladder / 2))

    -- price-estimation.md: BUY-1..3, FAIR-1..2
    local buy = { 950, 20, 1000, 40, 1100, 100 }
    local c1, f1 = Econ.CostToBuy(buy, 8)
    check("BUY-1", c1 == 7600 and f1, string.format("8 units cost %s", tostring(c1)))
    local c2, f2 = Econ.CostToBuy(buy, 70)
    check("BUY-2", c2 == 70000 and f2, string.format("70 units cost %s", tostring(c2)))
    local c3, f3, a3 = Econ.CostToBuy(buy, 200)
    check("BUY-3", c3 == 169000 and not f3 and a3 == 160, string.format("200 units: %s, filled %s, %s available",
        tostring(c3), tostring(f3), tostring(a3)))
    local fair = Econ.FairValue({ [100] = 100, [99] = 120, [97] = 80 }, 100, 3, 14)
    check("FAIR-1", near(fair, 102.561), string.format("fair value %s", tostring(fair)))
    check("FAIR-2", Econ.FairValue({ [80] = 100 }, 100) == nil, "nothing in the window -> unknown")

    -- crafting-economics.md: NET-1, MOB-1, ROI-0
    local net = Econ.AHNet(2900, 0.05, 60, 0.5)
    check("NET-1", near(net, 2695), string.format("AH net %s", tostring(net)))
    local mob = {
        vendorBuy = { [2840] = 60, [3576] = 90 },
        ladder = { [2841] = { 80, 10 } },
        recipeFor = { [2841] = { yield = 2, reagents = { 2840, 1, 3576, 1 } } },
    }
    local cost, source = Econ.Acquire(2841, 4, mob)
    check("MOB-1", cost == 300 and source == "craft", string.format("4 Bronze Bars: %s via %s (buying costs 320)",
        tostring(cost), tostring(source)))
    check("ROI-0", Econ.ROI(500, 0) == nil and near(Econ.ROI(55, 45), 1.22222), "ROI nil when nothing was spent")

    -- risk-and-recommendation.md grade table
    check("GRADE-A", Econ.Grade(3600, 5, 6, 0.10, 200, 50) == "A", "fresh, 5 days, steady, deep")
    check("GRADE-B", Econ.Grade(30 * 3600, 5, 6, 0.10, 200, 50) == "B", "a day and a half old")
    check("GRADE-C", Econ.Grade(3600, 1, 2, nil, 80, 50) == "C", "one day of data, two scans")
    check("GRADE-D", Econ.Grade(3600, 5, 6, 0.10, 40, 50) == "D", "can't fill the need")
    local _, whyC = Econ.Grade(3600, 1, 2, nil, 80, 50)
    local _, whyD = Econ.Grade(3600, 5, 6, 0.10, 40, 50)
    local _, whyB = Econ.Grade(30 * 3600, 5, 6, 0.10, 200, 50)
    check("GRADE-WHY", whyC == "days" and whyD == "depth" and whyB == "age",
        string.format("the deciding test: C %s, D %s, B %s", tostring(whyC), tostring(whyD), tostring(whyB)))
    return passed, failed
end
