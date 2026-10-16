local addonName, ns = ...

-- Vendor buy prices: what merchants charge, read while a merchant window is open
-- (professions-and-vendors.md "Vendor prices" [F-124]). On MERCHANT_SHOW and MERCHANT_UPDATE
-- (debounced), each item's unit price = price / stackCount; items with an extended cost
-- (tokens, currencies) are skipped; reputation discounts are already in the price.
-- Stored account-wide: BuffettForeverDB.vendor[itemID] = { p = unit copper, t = time,
-- lim = units in stock when the supply is limited }. The raw numAvailable values go to
-- diag.merchant, to settle what "unlimited" looks like on Forever (retail: -1).

local Merchant = {}
ns.Merchant = Merchant
local events = ns.events

local DEBOUNCE = 0.2
local SAMPLES = 8

local pending

local function Harvest()
    pending = nil
    if not ns.db or ns.readOnlyDB then return end
    local count = GetMerchantNumItems() or 0
    local now = GetServerTime()
    local vendor = ns.db.vendor
    local values, samples, stored = {}, {}, 0
    for i = 1, count do
        local info = C_MerchantFrame.GetItemInfo(i)
        local itemID = GetMerchantItemID(i)
        if info and itemID then
            local available = info.numAvailable
            local key = tostring(available)
            values[key] = (values[key] or 0) + 1
            if #samples < SAMPLES then
                samples[#samples + 1] = { itemID = itemID, numAvailable = available, stackCount = info.stackCount,
                                          price = info.price, extendedCost = info.hasExtendedCost or nil }
            end
            local price, stack = info.price or 0, info.stackCount or 0
            if not info.hasExtendedCost and price > 0 and stack > 0 then
                vendor[itemID] = { p = price / stack, t = now,
                                   lim = (type(available) == "number" and available > 0) and available or nil }
                stored = stored + 1
            end
        end
    end
    ns.db.diag.merchant = { t = now, items = count, stored = stored, numAvailable = values, samples = samples }
end

local function Schedule()
    if not pending then pending = C_Timer.NewTimer(DEBOUNCE, Harvest) end
end

function events:MERCHANT_SHOW()
    Schedule()
end

function events:MERCHANT_UPDATE()
    Schedule()
end

function events:MERCHANT_CLOSED()
    if pending then
        pending:Cancel()
        pending = nil
    end
end

-- The vendor's unit buy price for an item, its age in seconds and the limited stock (or nil).
function Merchant.Get(itemID)
    local row = ns.db and ns.db.vendor[itemID]
    if not row then return nil end
    return row.p, GetServerTime() - (row.t or 0), row.lim
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
