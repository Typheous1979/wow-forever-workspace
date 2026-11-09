local addonName, ns = ...

-- Item data that may not be cached yet: uncached lookups return nil, so request the load and
-- continue when it arrives (api-migration.md). Uses Blizzard's ContinuableContainer + Item mixin;
-- a failed load (an item this client doesn't have) still counts as done there. As a backstop,
-- Load gives up after LOAD_TIMEOUT seconds and continues with what it has.

local Items = {}
ns.Items = Items

local LOAD_TIMEOUT = 3

-- fn() runs once, when every item in itemIDs is loaded (at once if all are cached) or on timeout
-- (seconds; LOAD_TIMEOUT unless given).
function Items.Load(itemIDs, fn, timeout)
    local done = false
    local function finish()
        if done then return end
        done = true
        fn()
    end
    local container = ContinuableContainer:Create()
    for _, itemID in ipairs(itemIDs) do
        container:AddContinuable(Item:CreateFromItemID(itemID))
    end
    container:ContinueOnLoad(finish)
    if not done then
        C_Timer.After(timeout or LOAD_TIMEOUT, function()
            if done then return end
            container:Cancel()
            finish()
        end)
    end
end

-- The item's link, or "item 2589" while it isn't cached.
function Items.Link(itemID)
    local _, link = C_Item.GetItemInfo(itemID)
    return link or ("item " .. itemID)
end

-- The order Items.SellPrice takes, as a pure function for the selftest: the client's figure for a cached
-- item, else the data's; nil when neither knows.
function Items.ChooseSellPrice(live, data)
    if type(live) == "number" then return live end
    if type(data) == "number" then return data end
    return nil
end

-- What a vendor pays for one, in copper (0 when a vendor won't buy it), or nil while nobody knows yet.
-- The client's figure comes first once the item is cached: it carries Blizzard's hotfixes, which the
-- generated data can't (Mild Spices went from 2c to 1c on Nov 6, 2026 [F-141]). Then the data's
-- (Data/Recipes.lua, from the build's game tables). Last the client's again, which asks the server for the
-- item, so it's nil until the item loads. A cached item costs no server request.
function Items.SellPrice(itemID)
    local live
    if C_Item.IsItemDataCachedByID(itemID) then live = select(11, C_Item.GetItemInfo(itemID)) end
    local sell = Items.ChooseSellPrice(live, ns.ItemSellPrice and ns.ItemSellPrice[itemID])
    if sell == nil then sell = select(11, C_Item.GetItemInfo(itemID)) end
    if type(sell) ~= "number" then return nil end
    return sell
end

-- ---------------------------------------------------------------- self test

local function Count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

function Items.SelfTest(report)
    local passed, failed = 0, 0
    local function check(name, ok, detail)
        if ok then passed = passed + 1 else failed = failed + 1 end
        report(name, ok, detail)
    end
    local hotfixed, fallback = Items.ChooseSellPrice(1, 2), Items.ChooseSellPrice(nil, 2)
    local unsold, unknown = Items.ChooseSellPrice(0, 5), Items.ChooseSellPrice(nil, nil)
    check("SELL-PRICE", hotfixed == 1 and fallback == 2 and unsold == 0 and unknown == nil,
        string.format("the client's hotfixed 1c over the data's 2c: %s; the data's while uncached: %s; a vendor that "
            .. "no longer buys it: %s; nobody knows: %s", tostring(hotfixed), tostring(fallback), tostring(unsold),
            tostring(unknown)))
    -- Every cached item in the data: the price used is the client's. How many differ from the data (hotfixes)
    -- goes in diag.sellPrices, with a sample.
    local cached, wrong, differ, sample = 0, 0, 0, {}
    for itemID, data in pairs(ns.ItemSellPrice or {}) do
        if C_Item.IsItemDataCachedByID(itemID) then
            cached = cached + 1
            local live = select(11, C_Item.GetItemInfo(itemID))
            if Items.SellPrice(itemID) ~= live then wrong = wrong + 1 end
            if type(live) == "number" and live ~= data then
                differ = differ + 1
                if #sample < 10 then sample[#sample + 1] = string.format("%d: data %d, client %d", itemID, data, live) end
            end
        end
    end
    check("SELL-LIVE", wrong == 0, string.format("%d of the data's %d items cached; the client's price used for %d; "
        .. "%d differ from the data", cached, Count(ns.ItemSellPrice), cached - wrong, differ))
    if ns.db and not ns.readOnlyDB then
        ns.db.diag.sellPrices = { t = GetServerTime(), build = select(2, GetBuildInfo()), dataBuild = ns.RecipesBuild,
            cached = cached, differ = differ, sample = sample }
    end
    return passed, failed
end
