local addonName, ns = ...

-- Auction deposits (auction-house.md "Deposits and the house cut"), measured at the auctioneer with
-- the calls Blizzard's sell frame makes: CalculateCommodityDeposit(itemID, duration, quantity) for
-- commodities, CalculateItemDeposit(bag item, duration, quantity) for the rest. Measured at all three
-- durations for every bag item the AH would take and for the commodity outputs of the tray's recipes,
-- when the AH opens, after a full scan and when the tray changes there:
--   BuffettForeverDB.deposits[itemID] = { [1] = per unit, [2] = ..., [3] = ..., s = vendor price, t }
-- Deposits.Fit: deposit / what a vendor pays, over the measured items, estimates any other item (a
-- retail deposit is a share of the vendor price; diag.deposits checks that on Forever). The duration
-- is the one Blizzard's sell frame remembers (CVar auctionHouseDurationDropdown).
-- diag.deposits also keeps samples (is the deposit proportional to the quantity?), the durations'
-- names, and whether the call answers away from the AH. Fires DEPOSITS_CHANGED.

local L = ns.L
local Deposits = {}
ns.Deposits = Deposits

local DURATIONS = 3
local QTY = 100              -- commodity deposits are asked for 100 units, so per-unit rounding vanishes
local RATE_MIN = 3           -- measured items (that a vendor buys) before the rate estimates others
local OPEN_DELAY = 1         -- seconds after the AH opens
local CHANGE_DELAY = 0.5     -- after a tray change or a scan
local AWAY_DELAY = 5         -- after login: does the call answer away from the AH?
local SAMPLES = 10
local DURATION_NAMES = { "AUCTION_DURATION_ONE", "AUCTION_DURATION_TWO", "AUCTION_DURATION_THREE" }

local measured = {}          -- [itemID] = true once measured during this AH visit
local rates                  -- [duration] = rate or false, until the next measurement
local pending

local function Store()
    return ns.db.deposits
end

local function Diag()
    local diag = ns.db.diag
    diag.deposits = diag.deposits or {}
    local d = diag.deposits
    d.samples = d.samples or {}
    return d
end

-- The duration Blizzard's sell frame will use, 1 to 3.
function Deposits.Duration()
    local value = tonumber(C_CVar.GetCVar("auctionHouseDurationDropdown") or "")
    if value and value >= 1 and value <= DURATIONS then return math.floor(value) end
    return 2
end

-- Blizzard's name for a duration ("24 Hours" on retail), or "duration 2".
function Deposits.DurationName(d)
    d = d or Deposits.Duration()
    local name = DURATION_NAMES[d] and _G[DURATION_NAMES[d]]
    if type(name) == "string" then return name end
    return string.format(L["duration %d"], d)
end

local function VendorSell(itemID)
    local sell = ns.ItemSellPrice and ns.ItemSellPrice[itemID] or select(11, C_Item.GetItemInfo(itemID))
    if type(sell) ~= "number" then return nil end
    return sell
end

local function Sample(itemID, kind, qty, entry)
    local samples = Diag().samples
    for _, s in ipairs(samples) do
        if s.itemID == itemID then return end
    end
    if #samples < SAMPLES then
        samples[#samples + 1] = { itemID = itemID, kind = kind, qty = qty, sell = entry.s, entry[1], entry[2], entry[3] }
    end
end

-- deposit(d) gives the deposit for qty units at duration d; stores the per-unit deposits.
local function Measure(itemID, qty, deposit, kind)
    local per = {}
    for d = 1, DURATIONS do
        local ok, value = pcall(deposit, d)
        if not ok or type(value) ~= "number" or ns.IsSecret(value) then return nil end
        per[d] = value / qty
    end
    local entry = { per[1], per[2], per[3], s = VendorSell(itemID), t = GetServerTime() }
    measured[itemID] = true
    if ns.readOnlyDB then return entry end
    Store()[itemID] = entry
    rates = nil
    Sample(itemID, kind, qty, entry)
    return entry
end

function Deposits.MeasureCommodity(itemID)
    local entry = Measure(itemID, QTY, function(d)
        return C_AuctionHouse.CalculateCommodityDeposit(itemID, d, QTY)
    end, "commodity")
    if not entry then
        -- in case the game only prices what you could actually post
        entry = Measure(itemID, 1, function(d)
            return C_AuctionHouse.CalculateCommodityDeposit(itemID, d, 1)
        end, "commodity x1")
    end
    if not entry or ns.readOnlyDB then return entry end
    local d = Diag()
    if not d.linear then
        -- Is the deposit for 1 unit the per-unit deposit of 100, or is it rounded up per auction?
        local ok, one = pcall(C_AuctionHouse.CalculateCommodityDeposit, itemID, 1, 1)
        d.linear = { itemID = itemID, one = ok and one or nil, perUnitOf100 = entry[1] }
    end
    return entry
end

-- A bag item (ItemLocation): returns its entry and itemID, or nil when the AH wouldn't take it.
function Deposits.MeasureLocation(location)
    if not location or not C_Item.DoesItemExist(location) then return nil end
    local itemID = C_Item.GetItemID(location)
    if not itemID then return nil end
    local status = C_AuctionHouse.GetItemCommodityStatus(location)
    if status == Enum.ItemCommodityStatus.Commodity then
        return Deposits.MeasureCommodity(itemID), itemID
    elseif status == Enum.ItemCommodityStatus.Item then
        return Measure(itemID, 1, function(d)
            return C_AuctionHouse.CalculateItemDeposit(location, d, 1)
        end, "item"), itemID
    end
    return nil
end

local function MeasureBags()
    local count = 0
    for bag = Enum.BagIndex.Backpack, Enum.BagIndex.ReagentBag do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local itemID = C_Container.GetContainerItemID(bag, slot)
            if itemID and not measured[itemID] then
                local location = ItemLocation:CreateFromBagAndSlot(bag, slot)
                local ok, valid = pcall(C_AuctionHouse.IsSellItemValid, location, false)
                if ok and valid and Deposits.MeasureLocation(location) then count = count + 1 end
            end
        end
    end
    return count
end

-- Commodity outputs of the tray's recipes (item-key info that isn't cached yet waits for the next run).
local function MeasureTray()
    local ids = {}
    for _, entry in ipairs(ns.Tray.Entries()) do ids[#ids + 1] = entry.itemID end
    if #ids == 0 then return 0 end
    local count = 0
    for _, recipeID in ipairs(ns.RecipeIndex.UsingAny(ids, { confirmed = true })) do
        local output = ns.RecipeIndex.Get(recipeID).output
        if not measured[output] then
            local info = C_AuctionHouse.GetItemKeyInfo(C_AuctionHouse.MakeItemKey(output))
            if info and info.isCommodity and Deposits.MeasureCommodity(output) then count = count + 1 end
        end
    end
    return count
end

local function Run()
    pending = nil
    if not ns.ahOpen or not ns.db or ns.readOnlyDB then return end
    local bags, tray = MeasureBags(), MeasureTray()
    local d = Diag()
    local stored = 0
    for _ in pairs(Store()) do stored = stored + 1 end
    d.t, d.bags, d.tray, d.stored = GetServerTime(), bags, tray, stored
    d.duration, d.cvar = Deposits.Duration(), C_CVar.GetCVar("auctionHouseDurationDropdown")
    d.names, d.rates = {}, {}
    for k = 1, DURATIONS do
        d.names[k] = Deposits.DurationName(k)
        local rate, n, lo, hi = Deposits.Fit(Store(), k)
        d.rates[k] = { rate = rate, n = n, lo = lo, hi = hi }
    end
    if bags + tray > 0 then ns.Fire("DEPOSITS_CHANGED") end
end

local function Schedule(delay)
    if not pending then pending = C_Timer.NewTimer(delay, Run) end
end

-- deposit / vendor price over the entries a vendor buys, for duration d: rate (nil under RATE_MIN
-- entries), entries used, the lowest and the highest ratio.
function Deposits.Fit(entries, d)
    local deposit, sell, n, lo, hi = 0, 0, 0, nil, nil
    for _, entry in pairs(entries) do
        if entry[d] and (entry.s or 0) > 0 then
            deposit, sell, n = deposit + entry[d], sell + entry.s, n + 1
            local ratio = entry[d] / entry.s
            lo, hi = math.min(lo or ratio, ratio), math.max(hi or ratio, ratio)
        end
    end
    if n < RATE_MIN then return nil, n, lo, hi end
    return deposit / sell, n, lo, hi
end

local function Rate(d)
    rates = rates or {}
    if rates[d] == nil then rates[d] = Deposits.Fit(Store(), d) or false end
    return rates[d] or nil
end

-- The deposit per unit at duration d (default: the sell frame's): measured, or estimated from what a
-- vendor pays. Returns deposit, "measured" or "estimated"; nil when unknown.
function Deposits.PerUnit(itemID, d)
    if not ns.db then return nil end
    d = d or Deposits.Duration()
    local entry = Store()[itemID]
    if entry and entry[d] then return entry[d], "measured" end
    local rate, sell = Rate(d), VendorSell(itemID)
    if rate and sell and sell > 0 then return rate * sell, "estimated" end
    return nil
end

-- /bf diag: what the auctioneer said.
function Deposits.PrintDiag()
    local d = ns.db and ns.db.diag.deposits
    if not d then return end
    local parts = {}
    for k = 1, DURATIONS do
        local r = d.rates and d.rates[k]
        if r then
            parts[#parts + 1] = string.format("%s %s (%d items, %s to %s)", tostring(d.names and d.names[k] or k),
                r.rate and string.format("%.4f", r.rate) or "?", r.n or 0,
                r.lo and string.format("%.4f", r.lo) or "?", r.hi and string.format("%.4f", r.hi) or "?")
        end
    end
    ns.Print(string.format("deposits: %d items measured (%s bags, %s tray last time), duration %s (CVar %s); deposit/vendor: %s",
        d.stored or 0, tostring(d.bags or "-"), tostring(d.tray or "-"), tostring(d.duration or "-"), tostring(d.cvar),
        #parts > 0 and table.concat(parts, "; ") or "not measured yet"))
    if d.linear or d.away then
        ns.Print(string.format("deposits: 1 unit of %s costs %s (per unit of 100: %s); away from the AH the call gave %s",
            tostring(d.linear and d.linear.itemID or "-"), tostring(d.linear and d.linear.one or "-"),
            tostring(d.linear and d.linear.perUnitOf100 or "-"), tostring(d.away and d.away.value or "-")))
    end
end

-- ---------------------------------------------------------------- events

ns.On("AH_OPEN", function()
    wipe(measured)
    Schedule(OPEN_DELAY)
end)

ns.On("AH_CLOSED", function()
    if pending then
        pending:Cancel()
        pending = nil
    end
end)

ns.On("TRAY_CHANGED", function()
    if ns.ahOpen then Schedule(CHANGE_DELAY) end
end)

ns.On("SCAN_DONE", function()
    if ns.ahOpen then Schedule(CHANGE_DELAY) end
end)

ns.On("LOGIN", function()
    C_Timer.After(AWAY_DELAY, function()
        if not ns.db or ns.readOnlyDB or ns.ahOpen then return end
        local ok, value = pcall(C_AuctionHouse.CalculateCommodityDeposit, 2589, 1, 1)
        Diag().away = { ok = ok, value = type(value) == "number" and value or tostring(value), t = GetServerTime() }
    end)
end)

-- ---------------------------------------------------------------- self test

function Deposits.SelfTest(report)
    local passed, failed = 0, 0
    local function check(name, ok, detail)
        if ok then passed = passed + 1 else failed = failed + 1 end
        report(name, ok, detail)
    end
    local entries = {
        [1] = { 15, 30, 60, s = 100 },
        [2] = { 1.5, 3, 6, s = 10 },
        [3] = { 0.15, 0.3, 0.6, s = 1 },
        [4] = { 5, 10, 20, s = 0 },      -- a vendor won't buy it: left out of the fit
    }
    local rate, n, lo, hi = Deposits.Fit(entries, 2)
    check("DEP-FIT", rate and math.abs(rate - 0.3) < 1e-9 and n == 3 and math.abs(lo - hi) < 1e-9,
        string.format("deposit / vendor price at duration 2: %s over %d items", tostring(rate), n))
    check("DEP-FEW", Deposits.Fit({ [1] = { 15, 30, 60, s = 100 } }, 1) == nil, "one item doesn't estimate the rest")
    return passed, failed
end
