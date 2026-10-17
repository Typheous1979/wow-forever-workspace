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

-- Forever's deposit for one auction of qty units [F-129]: 5% of the vendor price per 2 hours, floored
-- to whole copper, times 1, 4 or 12 for durations 1, 2, 3 (2, 8, 24 hours), and at least 1s.
-- Dividing by 20 keeps the floor exact for whole-copper prices.
local DEPOSIT_DIVISOR, DEPOSIT_MIN = 20, 100
local DEPOSIT_MULT = { 1, 4, 12 }
Econ.DEPOSIT_MIN = DEPOSIT_MIN

function Econ.Deposit(vendorSell, qty, duration)
    return math.max(DEPOSIT_MIN, math.floor((vendorSell or 0) * qty / DEPOSIT_DIVISOR) * DEPOSIT_MULT[duration])
end

-- The deposit per unit when selling qty units: a commodity goes up as one auction of qty, anything
-- else (commodity == false) one auction per unit.
function Econ.DepositPerUnit(vendorSell, qty, duration, commodity)
    if qty <= 0 then return 0 end
    if commodity == false then return Econ.Deposit(vendorSell, 1, duration) end
    return Econ.Deposit(vendorSell, qty, duration) / qty
end

-- Liquidation value of one unit you own: the better of selling it to a vendor or on the AH.
function Econ.Liquidation(vendorSell, ahNet)
    if ahNet and vendorSell then return math.max(vendorSell, ahNet) end
    return ahNet or vendorSell
end

-- Sale chance from your sales ledger (crafting-economics.md "Sale chance"): units sold /
-- (sold + expired), pulled toward prior by weight pseudo-units so a few outcomes can't read as 0%
-- or 100%, and kept within [SALE_MIN, 1]. Cancelled auctions count neither way.
local SALE_MIN = 0.05
local MARKET_WEIGHT = 2      -- pseudo-units of the default behind your rate over all items
local ITEM_WEIGHT = 5        -- pseudo-units of that rate behind one item's own record

function Econ.SaleChance(sold, expired, prior, weight)
    sold, expired, prior, weight = sold or 0, expired or 0, prior or 0.5, weight or 0
    local n = sold + expired + weight
    if n <= 0 then return prior end
    return math.max(SALE_MIN, math.min(1, (sold + weight * prior) / n))
end

-- One item's sale chance: its own record, pulled toward your rate over all items in the market
-- (marketSold, marketExpired), which is pulled toward the default.
function Econ.ItemSaleChance(sold, expired, marketSold, marketExpired, default)
    local market = Econ.SaleChance(marketSold, marketExpired, default, MARKET_WEIGHT)
    return Econ.SaleChance(sold, expired, market, ITEM_WEIGHT), market
end

-- The house cut measured from seller invoices: total cut / total sales, once there are
-- CUT_MIN_SALES invoices worth CUT_MIN_COPPER together (copper rounding no longer matters); nil before.
local CUT_MIN_SALES, CUT_MIN_COPPER = 3, 10000
Econ.CUT_MIN_SALES = CUT_MIN_SALES

function Econ.MeasuredCut(cutTotal, bidTotal, sales)
    if (sales or 0) < CUT_MIN_SALES or (bidTotal or 0) < CUT_MIN_COPPER then return nil end
    local rate = cutTotal / bidTotal
    if rate < 0 or rate >= 0.5 then return nil end
    return rate
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

-- ---------------------------------------------------------------- market reality (M4 pass 2)

local STALE_DAYS, STALE_PRICE = 3, 0.01
local MOOD_DAYS, MOOD_Z, MOOD_SHARE = 5, 1.0, 0.10
Econ.STALE_DAYS = STALE_DAYS

-- A wall that never shrinks (risk-and-recommendation.md "Walls"). days = { { cheapest price, quantity
-- listed }, ... } oldest first, one per observed day. Counting back from the latest day: how many days
-- the cheapest price held (within 1%) while the quantity never fell. Returns days, price.
function Econ.StaleRun(days)
    local n = #days
    if n == 0 then return 0, nil end
    local price, run = days[n][1], 1
    for i = n - 1, 1, -1 do
        local older, newer = days[i], days[i + 1]
        if math.abs(older[1] - price) > price * STALE_PRICE or older[2] > newer[2] then break end
        run = run + 1
    end
    return run, price
end

-- Mr. Market (strategy-ideas.md): how far today's market value is from the fair value, as z (standard
-- deviations of the daily values in the window) and share (latest / fair - 1); and the fair value.
-- nil under MOOD_DAYS days of history, or with no spread.
function Econ.MrMarket(history, today, latest, window)
    window = window or 14
    local n, sum = 0, 0
    for day, v in pairs(history) do
        if today - day >= 0 and today - day < window then n, sum = n + 1, sum + v end
    end
    if n < MOOD_DAYS then return nil end
    local mean, var = sum / n, 0
    for day, v in pairs(history) do
        if today - day >= 0 and today - day < window then var = var + (v - mean) ^ 2 end
    end
    local sd = math.sqrt(var / n)
    local fair = Econ.FairValue(history, today, 3, window)
    if not fair or fair <= 0 or sd <= 0 then return nil end
    return (latest - fair) / sd, latest / fair - 1, fair
end

-- "cheap", "dear", or nil when it's within a standard deviation or 10% of fair value.
function Econ.Mood(z, share)
    if math.abs(z) < MOOD_Z or math.abs(share) < MOOD_SHARE then return nil end
    return z < 0 and "cheap" or "dear"
end

-- Listings without your own auctions: own = { unit price, qty, ... } takes its units from the listings
-- at its price (within half a copper). Returns the listings left and the units removed.
function Econ.ExcludeOwn(listings, own)
    local out, removed = {}, 0
    for i = 1, #listings do out[i] = listings[i] end
    for k = 1, #own, 2 do
        local price, left = own[k], own[k + 1]
        for i = 1, #out, 2 do
            if left <= 0 then break end
            if math.abs(out[i] - price) <= 0.5 and out[i + 1] > 0 then
                local take = math.min(left, out[i + 1])
                out[i + 1], left, removed = out[i + 1] - take, left - take, removed + take
            end
        end
    end
    local kept = {}
    for i = 1, #out, 2 do
        if out[i + 1] > 0 then
            kept[#kept + 1] = out[i]
            kept[#kept + 1] = out[i + 1]
        end
    end
    return kept, removed
end

-- AH listings below what a vendor pays (strategy-ideas.md "Vendor flip"): buy them, sell them to a
-- vendor. listings = { unit price, qty, ... }. Returns the units, their cost, their value at the vendor,
-- and the cheapest and dearest of them; 0 units when a vendor won't buy the item.
function Econ.Flip(listings, vendorSell)
    local qty, cost, lo, hi = 0, 0, nil, nil
    if not vendorSell or vendorSell <= 0 then return 0, 0, 0, nil, nil end
    for i = 1, #listings, 2 do
        local price = listings[i]
        if price < vendorSell then
            qty, cost = qty + listings[i + 1], cost + price * listings[i + 1]
            lo, hi = math.min(lo or price, price), math.max(hi or price, price)
        end
    end
    return qty, cost, qty * vendorSell, lo, hi
end

local GRADES = { "A", "B", "C", "D" }
Econ.GRADE_RANK = { A = 1, B = 2, C = 3, D = 4 }

-- Confidence grade of an AH price (risk-and-recommendation.md): the worst of age, days observed
-- (of 14; a single observation is D), volatility and depth. need nil = no depth test (an exit).
-- stale (a sell price only, when you haven't sold the item yourself): days its wall hasn't shrunk;
-- STALE_DAYS or more is D.
-- Also returns which test set the grade: "age", "single", "days", "volatile", "depth", "unlisted",
-- "stale" (the first one to reach the worst grade), or nil for A.
function Econ.Grade(ageSeconds, daysObserved, observations, cv, listed, need, stale)
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
    if stale and stale >= STALE_DAYS then worse(4, "stale") end
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

    -- crafting-economics.md: SALE-0..3 and CUT-1..3 (the sales ledger; computed in tools/wowf/econ.py)
    local function close(a, b) return type(a) == "number" and math.abs(a - b) < 1e-6 end
    check("SALE-0", Econ.SaleChance(0, 0, 0.5, 2) == 0.5, "no record: the prior")
    local s1 = Econ.SaleChance(18, 12, 0.5, 5)
    check("SALE-1", close(s1, 20.5 / 35), string.format("18 sold, 12 expired: %s", tostring(s1)))
    local s2 = Econ.SaleChance(0, 30, 0.5, 2)
    check("SALE-2", s2 == 0.05, string.format("30 expired, none sold: %s (floored at 5%%)", tostring(s2)))
    local s3 = Econ.ItemSaleChance(18, 12, 40, 30, 0.5)
    check("SALE-3", close(s3, 0.5956349206), string.format("18 of 30 sold, 40 of 70 over all items: %s", tostring(s3)))
    local cut = Econ.MeasuredCut(1500, 30000, 3)
    check("CUT-1", close(cut, 0.05), string.format("3 sales, 3g in total: %s", tostring(cut)))
    check("CUT-2", Econ.MeasuredCut(1000, 20000, 2) == nil and Econ.MeasuredCut(250, 5000, 4) == nil,
        "too few sales, or under 1g in total: not measured yet")
    check("CUT-3", Econ.MeasuredCut(0, 30000, 3) == 0, "no cut at all is a measurement too")

    -- crafting-economics.md: DEP-1..4, the game's own deposits on 70425 [F-129]
    local d1, d2, d3 = Econ.Deposit(142, 100, 1), Econ.Deposit(142, 100, 2), Econ.Deposit(142, 100, 3)
    check("DEP-1", d1 == 710 and d2 == 2840 and d3 == 8520,
        string.format("100 at a 142c vendor price: %s / %s / %s", tostring(d1), tostring(d2), tostring(d3)))
    check("DEP-2", Econ.Deposit(142, 1, 1) == 100, "one unit pays the 1s minimum")
    local g1, g2, g3 = Econ.Deposit(875, 1, 1), Econ.Deposit(875, 1, 2), Econ.Deposit(875, 1, 3)
    check("DEP-3", g1 == 100 and g2 == 172 and g3 == 516,
        string.format("gear at 875c: %s / %s / %s (floor before the multiplier)", tostring(g1), tostring(g2), tostring(g3)))
    local thread = Econ.DepositPerUnit(2, 2, 2, true)
    check("DEP-4", thread == 50 and Econ.DepositPerUnit(875, 5, 2, false) == 172,
        string.format("2 Coarse Thread for 8 hours: %s each; gear pays per auction", tostring(thread)))

    -- risk-and-recommendation.md: WALL-1..4, MOOD-1..3, OWN-1..3 (M4 pass 2; computed in econ.py)
    local w1, wp = Econ.StaleRun({ { 4400, 90 }, { 4400, 95 }, { 4400, 97 } })
    check("WALL-1", w1 == 3 and wp == 4400, string.format("44s held 3 days, 90 to 97 listed: %s days", tostring(w1)))
    check("WALL-2", Econ.StaleRun({ { 4400, 97 }, { 4400, 90 }, { 4400, 95 } }) == 2, "the quantity fell once: 2 days")
    check("WALL-3", Econ.StaleRun({ { 4500, 90 }, { 4400, 95 }, { 4400, 97 } }) == 2, "the price moved: 2 days")
    check("WALL-4", Econ.StaleRun({ { 4400, 90 }, { 4430, 90 }, { 4410, 95 } }) == 3, "within 1% counts as held")
    local z, share = Econ.MrMarket({ [96] = 1000, [97] = 1100, [98] = 900, [99] = 1000, [100] = 700 }, 100, 700)
    check("MOOD-1", close(z, -1.5167250658) and close(share, -0.2271500831) and Econ.Mood(z, share) == "cheap",
        string.format("700 against a fair value near 906: z %s, %s", tostring(z), tostring(share)))
    local z2, share2 = Econ.MrMarket({ [96] = 1000, [97] = 1000, [98] = 1010, [99] = 990, [100] = 1300 }, 100, 1300)
    check("MOOD-2", Econ.Mood(z2, share2) == "dear", string.format("1300 after a steady 1000: z %s", tostring(z2)))
    check("MOOD-3", Econ.MrMarket({ [99] = 1000, [100] = 700 }, 100, 700) == nil, "under 5 days: no mood")
    local own1, removed1 = Econ.ExcludeOwn({ 2900, 20, 2900, 8, 3100, 5 }, { 2900, 20 })
    check("OWN-1", table.concat(own1, ",") == "2900,8,3100,5" and removed1 == 20, "your 20 at 29s leave the listings")
    local own2, removed2 = Econ.ExcludeOwn({ 2900, 20, 2900, 8, 3100, 5 }, { 2900, 25 })
    check("OWN-2", table.concat(own2, ",") == "2900,3,3100,5" and removed2 == 25, "25 of yours across two rows")
    local own3, removed3 = Econ.ExcludeOwn({ 2900, 20 }, { 5000, 2 })
    check("OWN-3", table.concat(own3, ",") == "2900,20" and removed3 == 0, "yours at another price: nothing removed")
    local gs, gsWhy = Econ.Grade(3600, 5, 6, 0.10, 200, nil, 3)
    check("GRADE-STALE", gs == "D" and gsWhy == "stale" and Econ.Grade(3600, 5, 6, 0.10, 200, nil, 2) == "A",
        "a sell price walled for 3 days is D")

    -- strategy-ideas.md: FLIP-1..4 (M4 pass 3; computed in econ.py)
    local fq, fc, fv, flo, fhi = Econ.Flip({ 40, 5, 45, 10, 60, 20 }, 50)
    check("FLIP-1", fq == 15 and fc == 650 and fv == 750 and flo == 40 and fhi == 45,
        string.format("15 under a 50c vendor price: cost %s, worth %s", tostring(fc), tostring(fv)))
    check("FLIP-2", Econ.Flip({ 40, 5 }, 0) == 0, "a vendor won't buy it: no flip")
    check("FLIP-3", Econ.Flip({ 60, 5, 70, 1 }, 50) == 0, "nothing under the vendor price")
    local hq, hc, hv = Econ.Flip({ 49.5, 3 }, 50)
    check("FLIP-4", hq == 3 and close(hc, 148.5) and hv == 150, "half a copper under still counts")
    return passed, failed
end
