local addonName, ns = ...

-- Prices per market, stored as aggregates only (CLAUDE.md "Data model", wowf-economics
-- price-estimation.md "Storage shape"):
--   BuffettForeverDB.markets[marketKey] = {
--     items = { [itemID] = { t = time, mv = market value, min = min buyout, q = quantity,
--                            n = auctions, ladder = "p:q,p:q,...", h = { [day] = "mv:min:q:n:k" } } },
--     scan = { t, items, n },                       -- the last full scan of this market
--     flips = { t, list },                          -- its listings below a vendor's price (Pricing/Flips.lua)
--     ledger = { ... } }                            -- your own auction results (Pricing/Ledger.lua)
-- Prices are copper per unit, kept to 0.01 copper. A day is floor(serverTime / 86400). In the
-- day string, mv is the mean of that day's scans, min the lowest, q and n the latest, and k
-- counts the scans. n (auctions) comes from full scans; it can be missing ("mv:min:q::k") for an
-- item seen only in a commodity search.

local PriceDB = {}
ns.PriceDB = PriceDB

local SECONDS_PER_DAY = 86400

local function Round2(x)
    return math.floor(x * 100 + 0.5) / 100
end

-- "106.25", "100" (no trailing zeros), for the packed strings. %.0f, not %d: troll listings
-- reach 10^11 copper, past the 32-bit range of %d.
local function Num(x)
    local r = Round2(x)
    if r == math.floor(r) then return string.format("%.0f", r) end
    return (string.format("%.2f", r):gsub("0$", ""))
end

local function PackLadder(ladder)
    local parts = {}
    for i = 1, #ladder, 2 do
        parts[#parts + 1] = Num(ladder[i]) .. ":" .. ladder[i + 1]
    end
    return table.concat(parts, ",")
end

-- Flat { price1, qty1, ... } from "p:q,p:q".
function PriceDB.UnpackLadder(text)
    local ladder = {}
    for p, q in string.gmatch(text or "", "([%d%.]+):(%d+)") do
        ladder[#ladder + 1] = tonumber(p)
        ladder[#ladder + 1] = tonumber(q)
    end
    return ladder
end

-- mv, min, q, n, k from a day string.
function PriceDB.UnpackDay(text)
    local mv, min, q, n, k = strsplit(":", text or "")
    return tonumber(mv), tonumber(min), tonumber(q), tonumber(n), tonumber(k) or 1
end

function PriceDB.Today(now)
    return math.floor((now or GetServerTime()) / SECONDS_PER_DAY)
end

-- The one place that decides which characters share prices. The AH is per ruleset [F-081];
-- until the probes show who shares one: normalized realm + faction, Hardcore kept apart.
local marketKey
function PriceDB.MarketKey()
    if marketKey then return marketKey end
    local realm = GetNormalizedRealmName()
    local faction = UnitFactionGroup("player")
    if not realm or realm == "" or not faction then return nil end   -- too early in the login
    local key = realm .. "-" .. faction
    if C_GameRules.IsHardcoreActive() then key = key .. ":HC" end
    marketKey = key
    return key
end

-- This market's table; created on demand when create is true.
function PriceDB.Market(create)
    local key = PriceDB.MarketKey()
    if not key or not ns.db then return nil end
    local market = ns.db.markets[key]
    if not market and create then
        market = { items = {} }
        ns.db.markets[key] = market
    end
    return market
end

-- Store one item's listings from a scan or search. Returns the row, or nil. keepAuctions: the
-- listings are commodity search rows, grouped by unit price, so they hold no auction count;
-- keep the one from the last full scan.
function PriceDB.Record(itemID, listings, now, keepAuctions)
    if ns.readOnlyDB then return nil end
    local mv, min, q, n = ns.Econ.MarketValue(listings)
    if not mv then return nil end
    local market = PriceDB.Market(true)
    if not market then return nil end
    now = now or GetServerTime()
    local row = market.items[itemID]
    if not row then
        row = {}
        market.items[itemID] = row
    end
    if keepAuctions then n = row.n end
    row.t, row.mv, row.min, row.q, row.n = now, Round2(mv), Round2(min), q, n
    row.ladder = PackLadder(ns.Econ.BuildLadder(listings))

    row.h = row.h or {}
    local day = PriceDB.Today(now)
    local dayMV, dayMin, k = mv, min, 1
    if row.h[day] then
        local pmv, pmin, _, _, pk = PriceDB.UnpackDay(row.h[day])
        if pmv then
            dayMV = (pmv * pk + mv) / (pk + 1)
            k = pk + 1
        end
        if pmin and pmin < dayMin then dayMin = pmin end
    end
    row.h[day] = table.concat({ Num(dayMV), Num(dayMin), q, n or "", k }, ":")
    return row
end

-- The AH flips of the last full scan (Pricing/Flips.lua): { t, list = { "itemID:qty:cost:value:lo:hi" } }.
function PriceDB.NoteFlips(t, list)
    if ns.readOnlyDB then return end
    local market = PriceDB.Market(true)
    if market then market.flips = { t = t, list = list } end
end

-- The last scan's flips: its time and the packed list; nil before any.
function PriceDB.Flips()
    local market = PriceDB.Market()
    local flips = market and market.flips
    if not flips then return nil end
    return flips.t, flips.list
end

-- Remember the last full scan of this market (for the status line).
function PriceDB.NoteScan(now, items, auctions)
    if ns.readOnlyDB then return end
    local market = PriceDB.Market(true)
    if market then market.scan = { t = now, items = items, n = auctions } end
end

-- The latest row for an item in this market, and its age in seconds; nil when never seen.
function PriceDB.Get(itemID)
    local market = PriceDB.Market()
    local row = market and market.items[itemID]
    if not row then return nil end
    return row, GetServerTime() - (row.t or 0)
end

-- A row's daily market values { [day] = mv }, the number of days, and the scans behind them.
function PriceDB.History(row)
    local history, days, observations = {}, 0, 0
    for day, text in pairs(row and row.h or {}) do
        local mv, _, _, _, k = PriceDB.UnpackDay(text)
        if mv then
            history[day] = mv
            days = days + 1
            observations = observations + (k or 1)
        end
    end
    return history, days, observations
end

-- A row's days in order, oldest first: { { day, mv, min, q }, ... } (q = the day's latest quantity).
function PriceDB.Days(row)
    local days = {}
    for day, text in pairs(row and row.h or {}) do
        local mv, min, q = PriceDB.UnpackDay(text)
        if mv and min and q then days[#days + 1] = { day, mv, min, q } end
    end
    table.sort(days, function(a, b) return a[1] < b[1] end)
    return days
end

-- Days the cheapest price has held (within 1%) while the quantity listed never fell, up to today
-- (Econ.StaleRun over the history window), and that price.
function PriceDB.StaleRun(row, today, window)
    local days = {}
    for _, d in ipairs(PriceDB.Days(row)) do
        if today - d[1] < window then days[#days + 1] = { d[3], d[4] } end
    end
    return ns.Econ.StaleRun(days)
end

-- Number of items priced in this market, and the last full scan ({ t, items, n }) if any.
function PriceDB.Summary()
    local market = PriceDB.Market()
    if not market then return 0, nil end
    local count = 0
    for _ in pairs(market.items) do count = count + 1 end
    return count, market.scan
end

-- Drop history days older than settings.historyDays, and items with no recent scan and no
-- history left. Runs at login, across every market. Returns the number of items removed.
function PriceDB.Prune(now)
    if ns.readOnlyDB then return 0 end
    now = now or GetServerTime()
    local keepDays = ns.db.settings.historyDays or 14
    local oldestDay = PriceDB.Today(now) - keepDays + 1
    local cutoff = now - keepDays * SECONDS_PER_DAY
    local removed = 0
    for _, market in pairs(ns.db.markets) do
        local items = market.items or {}
        for itemID, row in pairs(items) do
            if row.h then
                for day in pairs(row.h) do
                    if day < oldestDay then row.h[day] = nil end
                end
                if next(row.h) == nil then row.h = nil end
            end
            if not row.h and (row.t or 0) < cutoff then
                items[itemID] = nil
                removed = removed + 1
            end
        end
    end
    return removed
end

ns.On("LOGIN", function()
    PriceDB.Prune()
end)
