local addonName, ns = ...

-- Your active auctions (auction-house.md "Your auctions"): when the AH opens, QueryOwnedAuctions
-- (through the search throttle, Search.WhenReady), then OWNED_AUCTIONS_UPDATED -> GetOwnedAuctions().
-- It tells the ledger what you have listed (units, auctions and unit prices per item, so a full scan
-- can leave your own auctions out of the market) and the names your sales mail will use (an item
-- link's name -> its itemID). Posting (AUCTION_HOUSE_AUCTION_CREATED, also passed on as
-- AUCTION_CREATED(auctionID) for Pricing/Post.lua) and cancelling (AUCTION_CANCELED) ask again. Sold
-- auctions (waiting for their mail) aren't listed.
-- diag.owned keeps the raw fields of the first auctions it sees: is buyoutAmount per unit or per
-- auction?

local Owned = {}
ns.Owned = Owned
local events = ns.events

local DELAY = 1              -- seconds after the AH opens, a post or a cancel
local SAMPLES = 10
local SORTS = { { sortOrder = Enum.AuctionHouseSortOrder.Name, reverseSort = false } }

local pending

local function Diag()
    ns.db.diag.owned = ns.db.diag.owned or {}
    return ns.db.diag.owned
end

local function Query()
    pending = nil
    if not ns.ahOpen or not ns.db then return end
    ns.Search.WhenReady(function()
        if not ns.ahOpen then return end
        C_AuctionHouse.QueryOwnedAuctions(SORTS)
        if not ns.readOnlyDB then
            local d = Diag()
            d.queries, d.queried = (d.queries or 0) + 1, GetServerTime()
        end
    end)
end

local function Schedule()
    if not pending then pending = C_Timer.NewTimer(DELAY, Query) end
end

-- "Bolt of Linen Cloth" from an item link.
local function NameOf(link)
    if type(link) ~= "string" or ns.IsSecret(link) then return nil end
    return string.match(link, "|h%[(.-)%]|h")
end

local function Read()
    if not ns.db or ns.readOnlyDB then return end
    local ok, list = pcall(C_AuctionHouse.GetOwnedAuctions)
    if not ok or type(list) ~= "table" then return end
    local now, d = GetServerTime(), Diag()
    -- the first auctions ever seen stay as samples, so a later look at an empty list can't erase them
    local samples, sampled = d.samples or {}, {}
    for _, s in ipairs(samples) do sampled[s.auctionID or 0] = true end
    local listed, sold = {}, 0
    for _, a in ipairs(list) do
        local itemID = a.itemKey and a.itemKey.itemID
        if itemID and not ns.IsSecret(itemID) then
            if a.status == Enum.AuctionStatus.Sold then
                sold = sold + 1
            else
                local entry = listed[itemID] or { q = 0, n = 0, levels = {} }
                entry.q, entry.n = entry.q + (a.quantity or 0), entry.n + 1
                -- the unit price, to leave your auctions out of the market (a commodity's buyout is per
                -- unit [F-131]; an item's is taken as per auction, like its search results)
                local buyout, qty = a.buyoutAmount, a.quantity or 0
                if type(buyout) == "number" and buyout > 0 and qty > 0 then
                    local unit = ns.Deposits.IsCommodity(itemID) and buyout or buyout / qty
                    entry.levels[#entry.levels + 1] = unit
                    entry.levels[#entry.levels + 1] = qty
                end
                listed[itemID] = entry
            end
            local name = NameOf(a.itemLink)
            if name then ns.Ledger.LearnName(name, itemID) end
            if #samples < SAMPLES and a.auctionID and not sampled[a.auctionID] then
                sampled[a.auctionID] = true
                samples[#samples + 1] = { auctionID = a.auctionID, itemID = itemID, quantity = a.quantity,
                    buyoutAmount = a.buyoutAmount, bidAmount = a.bidAmount, status = a.status,
                    timeLeftSeconds = a.timeLeftSeconds, t = now }
            end
        end
    end
    ns.Ledger.SetListed(listed, now)
    d.t, d.auctions, d.sold, d.samples = now, #list, sold, samples
    d.full = C_AuctionHouse.HasFullOwnedAuctionResults()
    ns.Fire("LEDGER_CHANGED")
end

function events:OWNED_AUCTIONS_UPDATED()
    Read()
end

function events:AUCTION_HOUSE_AUCTION_CREATED(auctionID)
    if ns.ahOpen then Schedule() end
    ns.Fire("AUCTION_CREATED", auctionID)
end

function events:AUCTION_CANCELED()
    if ns.ahOpen then Schedule() end
end

-- /bf diag: the last look at your auctions.
function Owned.PrintDiag()
    local d = ns.db and ns.db.diag.owned
    if not d or not d.t then return end
    local last = d.samples and d.samples[#d.samples]
    ns.Print(string.format("your auctions %s: %d (%d sold, waiting for the mail), full %s, %d queries%s",
        date("%H:%M:%S", d.t), d.auctions or 0, d.sold or 0, tostring(d.full), d.queries or 0,
        last and string.format("; latest sample: item %s x%s, buyout %s, bid %s, %s s left", tostring(last.itemID),
            tostring(last.quantity), tostring(last.buyoutAmount), tostring(last.bidAmount),
            tostring(last.timeLeftSeconds)) or ""))
end

ns.On("AH_OPEN", Schedule)

ns.On("AH_CLOSED", function()
    if pending then
        pending:Cancel()
        pending = nil
    end
end)

ns.eventFrame:RegisterEvent("OWNED_AUCTIONS_UPDATED")
ns.eventFrame:RegisterEvent("AUCTION_HOUSE_AUCTION_CREATED")
ns.eventFrame:RegisterEvent("AUCTION_CANCELED")
