local addonName, ns = ...

-- AH flips (wowf-economics strategy-ideas.md "Vendor flip"): listings priced below what a vendor pays.
-- Buy them on the AH and sell them to a vendor: certain profit while the listings last. Found during
-- each full scan from every listing, your own left out (Scanner calls Flips.Find), and kept per market:
--   markets[marketKey].flips = { t = scan time, list = { "itemID:qty:cost:value:lo:hi", ... } }
-- Flips.Results() gives the AH flips view its rows, in the shape of evaluator results (cogs = cost,
-- best = the vendor's price, a grade from the scan's age: listings vanish fast). Buying stays the
-- player's click.

local L = ns.L
local Econ = ns.Econ
local Flips = {}
ns.Flips = Flips

local AGES = { { 15 * 60, "A" }, { 3600, "B" }, { 6 * 3600, "C" } }   -- older than the last: D

-- What a vendor pays for the item; nil while the item isn't cached (a later scan finds it).
local function VendorSell(itemID)
    local sell = ns.ItemSellPrice and ns.ItemSellPrice[itemID] or select(11, C_Item.GetItemInfo(itemID))
    if type(sell) ~= "number" then return nil end
    return sell
end

-- One item's listings during a full scan: its flip as a packed string, or nil (and true when the
-- vendor price isn't known yet).
function Flips.Find(itemID, listings)
    local sell = VendorSell(itemID)
    if not sell then return nil, true end
    local qty, cost, value, lo, hi = Econ.Flip(listings, sell)
    if qty == 0 then return nil end
    return string.format("%d:%d:%.0f:%.0f:%.2f:%.2f", itemID, qty, cost, value, lo, hi)
end

-- The confidence in a flip from the scan's age: A under 15 min, B under 1 h, C under 6 h, else D.
function Flips.AgeGrade(age)
    for _, a in ipairs(AGES) do
        if age < a[1] then return a[2] end
    end
    return "D"
end

-- The flips of the last full scan as list rows, recommended first, then by profit; and the scan time.
function Flips.Results()
    local t, list = ns.PriceDB.Flips()
    local results = {}
    if not t then return results, nil end
    local s = ns.db.settings
    local age = GetServerTime() - t
    local grade = Flips.AgeGrade(age)
    for _, text in ipairs(list or {}) do
        local itemID, qty, cost, value, lo, hi = strsplit(":", text)
        itemID, qty, cost, value = tonumber(itemID), tonumber(qty), tonumber(cost), tonumber(value)
        if itemID and qty and cost and value then
            local profit = value - cost
            local r = {
                flip = true, view = "flips", recipe = { recipeID = itemID, output = itemID, count = 1 }, crafts = 1,
                units = qty, complete = true, cogs = cost, best = value, bestSource = "vendor", vendorExit = value,
                profit = profit, roi = Econ.ROI(profit, cost), grade = grade, lo = tonumber(lo), hi = tonumber(hi),
                t = t, age = age, lines = {}, warnings = {}, reasons = {},
            }
            if profit < s.minProfit then r.reasons[#r.reasons + 1] = "underMinProfit" end
            if Econ.GRADE_RANK[grade] > Econ.GRADE_RANK[s.minGrade] then r.reasons[#r.reasons + 1] = "thinData" end
            r.recommended = #r.reasons == 0
            results[#results + 1] = r
        end
    end
    table.sort(results, function(a, b)
        if a.recommended ~= b.recommended then return a.recommended end
        if a.profit ~= b.profit then return a.profit > b.profit end
        return a.recipe.output < b.recipe.output
    end)
    return results, t
end

-- One line of advice for a flip (the Top pick panel).
function Flips.Advice(r, name)
    if r.recommended then
        return string.format(L["Buy %d x %s on the AH (up to %s each) and sell them to a vendor: +%s."], r.units, name,
            ns.Money.Format(r.hi or 0), ns.Money.Format(r.profit))
    end
    local why = {}
    for _, key in ipairs(r.reasons) do why[#why + 1] = ns.Evaluator.ReasonText(key) end
    return string.format(L["%s: not recommended (%s)."], name, table.concat(why, ", "))
end
