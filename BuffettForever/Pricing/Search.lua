local addonName, ns = ...

-- Targeted Auction House searches: the current listings of one item (auction-house.md
-- "Targeted searches"). A queue with one query in flight, sent only when the throttle is
-- ready (IsThrottledMessageSystemReady / AUCTION_HOUSE_THROTTLED_SYSTEM_READY) and never
-- during a full scan. It follows Blizzard's sell frame: the item key comes from the bag slot
-- when there is one (GetItemKeyFromItem); commodities and plain items use SendSearchQuery,
-- equipment uses SendSellSearchQuery with item level and suffix cleared (all variants).
-- Results arrive as COMMODITY_SEARCH_RESULTS_UPDATED/ADDED or ITEM_SEARCH_RESULTS_UPDATED/ADDED;
-- up to MAX_PAGES pages are read, then PriceDB.Record stores them like a scan.
--   Search.Request(itemID, itemKey or nil, callback(itemID, result, problem))
--   result = { mv, min, q, n or prices, full } (full = every listing was read), or nil with a
--   problem. Commodity rows are grouped by unit price [F-121], so a commodity result counts
--   prices, not auctions (n stays nil).

local L = ns.L
local Search = {}
ns.Search = Search
local events = ns.events

local FIRST_TIMEOUT = 15   -- seconds for the first page (includes waiting for the throttle)
local PAGE_TIMEOUT = 10    -- seconds for each further page
local MAX_PAGES = 5
local DIAG_KEEP = 20
local SORTS = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }

local READY_GAP = 0.2       -- seconds between two messages sent on one throttle-ready

local queue = {}      -- { itemID, key } waiting to be sent, in order
local callbacks = {}  -- [itemID] = { fn, ... } for queued and in-flight items
local current         -- the query in flight
local readyQueue = {} -- what to send once the throttle is ready, oldest first (searches, Pricing/Owned.lua)

local function NowMs()
    return debugprofilestop()
end

local function Notify(itemID, result, problem)
    local list = callbacks[itemID]
    callbacks[itemID] = nil
    for _, fn in ipairs(list or {}) do
        local ok, err = pcall(fn, itemID, result, problem)
        if not ok then geterrorhandler()(err) end
    end
end

-- One waiting message per throttle-ready, the next one READY_GAP later. A message whose query is
-- gone (timed out, the AH closed) does nothing, so the next one goes out.
local function RunReady()
    if #readyQueue == 0 or not ns.ahOpen or not C_AuctionHouse.IsThrottledMessageSystemReady() then return end
    local fn = table.remove(readyQueue, 1)
    fn()
    if #readyQueue > 0 then C_Timer.After(READY_GAP, RunReady) end
end

-- Send now if the throttle allows, else as soon as AUCTION_HOUSE_THROTTLED_SYSTEM_READY fires, in
-- the order asked. Shared by every AH message BuffettForever sends.
function Search.WhenReady(fn)
    readyQueue[#readyQueue + 1] = fn
    RunReady()
end
local WhenReady = Search.WhenReady

function events:AUCTION_HOUSE_THROTTLED_SYSTEM_READY()
    RunReady()
end

-- commodity, equipment or item from the item-key info; if that isn't cached yet, equipment by
-- item class, and "unknown" otherwise (the results event then tells commodity from item).
local function Kind(itemID, key)
    local info = C_AuctionHouse.GetItemKeyInfo(key)
    if info then
        if info.isCommodity then return "commodity" end
        if info.isEquipment then return "equipment" end
        return "item"
    end
    local _, _, _, _, _, classID = C_Item.GetItemInfoInstant(itemID)
    if classID == Enum.ItemClass.Weapon or classID == Enum.ItemClass.Armor then return "equipment" end
    return "unknown"
end

local function ReadCommodity(q)
    local listings = {}
    local n = C_AuctionHouse.GetNumCommoditySearchResults(q.itemID) or 0
    for i = 1, n do
        local r = C_AuctionHouse.GetCommoditySearchResultInfo(q.itemID, i)
        if r and (r.quantity or 0) > 0 and (r.unitPrice or 0) > 0 then
            listings[#listings + 1] = r.unitPrice
            listings[#listings + 1] = r.quantity
        end
    end
    return listings, n, C_AuctionHouse.HasFullCommoditySearchResults(q.itemID)
end

-- buyoutAmount pays for the whole auction (Blizzard's buy frame bids it), so unit = buyout / quantity.
local function ReadItems(q)
    local listings = {}
    local n = C_AuctionHouse.GetNumItemSearchResults(q.key) or 0
    for i = 1, n do
        local r = C_AuctionHouse.GetItemSearchResultInfo(q.key, i)
        if r and (r.quantity or 0) > 0 and (r.buyoutAmount or 0) > 0 then
            listings[#listings + 1] = r.buyoutAmount / r.quantity
            listings[#listings + 1] = r.quantity
        end
    end
    return listings, n, C_AuctionHouse.HasFullItemSearchResults(q.key)
end

local function Finish(q, problem)
    if current ~= q then return end
    current = nil
    if q.timer then q.timer:Cancel() end
    local result
    local listings = q.listings
    if not problem then
        if not listings or #listings == 0 then
            problem = (q.n or 0) == 0 and L["none listed."] or L["listed, but bid-only."]
        else
            local mv, min, qty, rows = ns.Econ.MarketValue(listings)
            local commodity = q.kind == "commodity"
            result = { mv = mv, min = min, q = qty, full = q.full }
            if commodity then result.prices = rows else result.n = rows end
            ns.PriceDB.Record(q.itemID, listings, nil, commodity)
        end
    end
    if ns.db and not ns.readOnlyDB then
        local diag = ns.db.diag
        diag.searches = diag.searches or {}
        diag.searches[#diag.searches + 1] = {
            t = q.t, itemID = q.itemID, kind = q.kind, results = q.n, pages = q.pages, full = q.full,
            ms = math.floor(NowMs() - q.started), problem = problem,
        }
        while #diag.searches > DIAG_KEEP do table.remove(diag.searches, 1) end
    end
    Notify(q.itemID, result, problem)
    Search.Pump()
end

local function OnTimeout(q)
    if current ~= q then return end
    if q.pages > 0 then
        Finish(q)   -- keep the pages we have
    elseif q.awaiting then
        Finish(q, L["no answer from the Auction House."])
    else
        Finish(q, L["the Auction House is busy (throttled); try again in a moment."])
    end
end

-- A page of results is in: read it, then ask for more until full or MAX_PAGES.
local function OnResults(q, kind)
    if current ~= q or not q.awaiting then return end
    q.awaiting = false
    if q.timer then q.timer:Cancel() end
    if q.kind == "unknown" then q.kind = kind end
    q.pages = q.pages + 1
    local reader = kind == "commodity" and ReadCommodity or ReadItems
    q.listings, q.n, q.full = reader(q)
    if q.full or q.pages >= MAX_PAGES or q.n == 0 then
        Finish(q)
        return
    end
    q.timer = C_Timer.NewTimer(PAGE_TIMEOUT, function() OnTimeout(q) end)
    WhenReady(function()
        if current ~= q then return end
        q.awaiting = true
        local full
        if kind == "commodity" then
            full = C_AuctionHouse.RequestMoreCommoditySearchResults(q.itemID)
        else
            full = C_AuctionHouse.RequestMoreItemSearchResults(q.key)
        end
        if full then OnResults(q, kind) end   -- everything was already here: no event follows
    end)
end

local function Send(entry)
    local itemID = entry.itemID
    local key = entry.key or C_AuctionHouse.MakeItemKey(itemID)
    local kind = Kind(itemID, key)
    if kind == "equipment" then
        key = { itemID = key.itemID, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = key.battlePetSpeciesID or 0 }
    end
    local q = { itemID = itemID, key = key, kind = kind, pages = 0, t = GetServerTime(), started = NowMs() }
    current = q
    q.timer = C_Timer.NewTimer(FIRST_TIMEOUT, function() OnTimeout(q) end)
    WhenReady(function()
        if current ~= q then return end
        q.awaiting = true
        if kind == "equipment" then
            C_AuctionHouse.SendSellSearchQuery(key, SORTS, false)
        else
            C_AuctionHouse.SendSearchQuery(key, SORTS, false)
        end
    end)
end

function Search.Pump()
    if current or #queue == 0 or not ns.ahOpen or ns.Scanner.IsBusy() then return end
    Send(table.remove(queue, 1))
end

-- Queue a search; the same item asked twice shares one query. Returns false when not at the AH.
function Search.Request(itemID, itemKey, callback)
    if not ns.ahOpen then
        if callback then callback(itemID, nil, L["open the Auction House to search."]) end
        return false
    end
    local list = callbacks[itemID]
    if list then
        if callback then list[#list + 1] = callback end
        return true
    end
    callbacks[itemID] = { callback }
    queue[#queue + 1] = { itemID = itemID, key = itemKey }
    Search.Pump()
    return true
end

function Search.IsQueued(itemID)
    return callbacks[itemID] ~= nil
end

-- /bf diag: the last few searches.
function Search.PrintDiag()
    local list = ns.db and ns.db.diag.searches
    if not list or #list == 0 then return end
    for i = math.max(1, #list - 4), #list do
        local s = list[i]
        ns.Print(string.format("search %s: item %d (%s), %s results, %s pages, full %s, %s ms%s", date("%H:%M:%S", s.t),
            s.itemID, tostring(s.kind), tostring(s.results or "-"), tostring(s.pages), tostring(s.full),
            tostring(s.ms), s.problem and (", " .. s.problem) or ""))
    end
end

function events:COMMODITY_SEARCH_RESULTS_UPDATED(itemID)
    if current and current.itemID == itemID then OnResults(current, "commodity") end
end
events.COMMODITY_SEARCH_RESULTS_ADDED = events.COMMODITY_SEARCH_RESULTS_UPDATED

function events:ITEM_SEARCH_RESULTS_UPDATED(itemKey)
    if current and type(itemKey) == "table" and itemKey.itemID == current.itemID then OnResults(current, "item") end
end
events.ITEM_SEARCH_RESULTS_ADDED = events.ITEM_SEARCH_RESULTS_UPDATED

ns.On("SCAN_DONE", function() Search.Pump() end)

ns.On("AH_CLOSED", function()
    wipe(readyQueue)
    local pending = queue
    queue = {}
    if current then Finish(current, L["the Auction House closed."]) end
    for _, entry in ipairs(pending) do Notify(entry.itemID, nil, L["the Auction House closed."]) end
end)

for _, event in ipairs({ "AUCTION_HOUSE_THROTTLED_SYSTEM_READY", "COMMODITY_SEARCH_RESULTS_UPDATED",
    "COMMODITY_SEARCH_RESULTS_ADDED", "ITEM_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_ADDED" }) do
    ns.eventFrame:RegisterEvent(event)
end
