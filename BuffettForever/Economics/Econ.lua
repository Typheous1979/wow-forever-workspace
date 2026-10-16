local addonName, ns = ...

-- Pure pricing functions from the wowf-economics references (price-estimation.md). No game
-- state in here: numbers in, numbers out, so /bf selftest can check them against the
-- reference test vectors. M3 adds FairValue, CostToBuy and the crafting math.
-- Listings are flat { unitPrice1, qty1, unitPrice2, qty2, ... } in copper per unit.

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
    return passed, failed
end
