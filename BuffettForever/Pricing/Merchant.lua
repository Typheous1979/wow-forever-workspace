local addonName, ns = ...

-- Vendor buy prices: what merchants charge, read while a merchant window is open
-- (professions-and-vendors.md "Vendor prices" [F-124]). On MERCHANT_SHOW and MERCHANT_UPDATE
-- (debounced), each item's unit price = price / stackCount; items with an extended cost
-- (tokens, currencies) are skipped; reputation discounts are already in the price.
-- Stored account-wide: BuffettForeverDB.vendor[itemID] = { p = unit copper, t = time,
-- lim = units in stock when the supply is limited }. The raw numAvailable values go to
-- diag.merchant, to settle what "unlimited" looks like on Forever (retail: -1).
-- While the window is open, Merchant.Find(itemID) gives the merchant's slot for buying it (the Buy
-- bar, Pricing/Buy.lua): its index, the price for stackCount units, the most one BuyMerchantItem buys
-- (GetMerchantItemMaxStack) and the stock. MERCHANT_OPEN, MERCHANT_ITEMS and MERCHANT_CLOSED tell the bar.

local Merchant = {}
ns.Merchant = Merchant
local events = ns.events

local DEBOUNCE = 0.2
local SAMPLES = 8

local pending
local open = false
local slots = {}   -- [itemID] = { index, price, stack, maxStack, available } at the open merchant

local function Harvest()
    pending = nil
    if not ns.db or ns.readOnlyDB then return end
    local count = GetMerchantNumItems() or 0
    local now = GetServerTime()
    local vendor = ns.db.vendor
    local values, samples, stored = {}, {}, 0
    wipe(slots)
    for i = 1, count do
        local info = C_MerchantFrame.GetItemInfo(i)
        local itemID = GetMerchantItemID(i)
        if info and itemID then
            local available = info.numAvailable
            local key = tostring(available)
            values[key] = (values[key] or 0) + 1
            local maxStack = GetMerchantItemMaxStack(i)
            if #samples < SAMPLES then
                samples[#samples + 1] = { itemID = itemID, numAvailable = available, stackCount = info.stackCount,
                                          price = info.price, extendedCost = info.hasExtendedCost or nil, maxStack = maxStack }
            end
            local price, stack = info.price or 0, info.stackCount or 0
            if not info.hasExtendedCost and price > 0 and stack > 0 then
                vendor[itemID] = { p = price / stack, t = now,
                                   lim = (type(available) == "number" and available > 0) and available or nil }
                stored = stored + 1
                if not slots[itemID] then
                    slots[itemID] = { index = i, price = price, stack = stack, maxStack = maxStack, available = available }
                end
            end
        end
    end
    ns.db.diag.merchant = { t = now, items = count, stored = stored, numAvailable = values, samples = samples }
    if stored > 0 then ns.Fire("VENDOR_PRICES_CHANGED") end
    ns.Fire("MERCHANT_ITEMS")
end

-- How many to buy in one BuyMerchantItem for need units (Blizzard's stack split, MerchantFrame.lua): whole
-- stacks of stackCount, at most maxStack a purchase, at most what's in stock (available -1: unlimited).
-- 0 when not even one stack can be had. (Pure: the self-test runs it.)
function Merchant.BuyQty(need, stackCount, maxStack, available)
    stackCount = math.max(1, stackCount or 1)
    local qty = math.ceil(need / stackCount) * stackCount
    if type(maxStack) == "number" and maxStack > 0 then
        qty = math.min(qty, math.floor(maxStack / stackCount) * stackCount)
    end
    if type(available) == "number" and available >= 0 then
        qty = math.min(qty, math.floor(available / stackCount) * stackCount)
    end
    return math.max(0, qty)
end

-- The open merchant's slot for an item it sells for gold: { index, price (for stack units), stack, maxStack,
-- available }, or nil. Checked against the merchant's list now, as a page or a purchase can move it.
function Merchant.Find(itemID)
    local slot = open and slots[itemID]
    if not slot or GetMerchantItemID(slot.index) ~= itemID then return nil end
    return slot
end

function Merchant.IsOpen()
    return open
end

local function Schedule()
    if not pending then pending = C_Timer.NewTimer(DEBOUNCE, Harvest) end
end

function events:MERCHANT_SHOW()
    open = true
    Schedule()
    ns.Fire("MERCHANT_OPEN")
end

function events:MERCHANT_UPDATE()
    Schedule()
end

function events:MERCHANT_CLOSED()
    if pending then
        pending:Cancel()
        pending = nil
    end
    if not open then return end   -- it can fire twice
    open = false
    wipe(slots)
    ns.Fire("MERCHANT_CLOSED")
end

-- The vendor's unit buy price for an item, its age in seconds and the limited stock (or nil).
-- A price harvested at a merchant wins; else the seed list (Data/Vendor.lua, age nil).
function Merchant.Get(itemID)
    local row = ns.db and ns.db.vendor[itemID]
    if row then return row.p, GetServerTime() - (row.t or 0), row.lim end
    local seed = ns.VendorSeed and ns.VendorSeed[itemID]
    if seed then return seed, nil, nil end
    return nil
end

-- /bf diag: the last merchant visit.
function Merchant.PrintDiag()
    local m = ns.db and ns.db.diag.merchant
    if not m then return end
    local parts = {}
    for value, n in pairs(m.numAvailable or {}) do parts[#parts + 1] = value .. " x" .. n end
    table.sort(parts)
    ns.Print(string.format("merchant %s: %d items, %d prices stored; numAvailable values: %s",
        date("%H:%M:%S", m.t), m.items or 0, m.stored or 0, table.concat(parts, ", ")))
end

ns.eventFrame:RegisterEvent("MERCHANT_SHOW")
ns.eventFrame:RegisterEvent("MERCHANT_UPDATE")
ns.eventFrame:RegisterEvent("MERCHANT_CLOSED")
