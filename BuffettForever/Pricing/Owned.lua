local addonName, ns = ...

-- Your active auctions (auction-house.md "Your auctions"): when the AH opens, QueryOwnedAuctions
-- (through the search throttle, Search.WhenReady), then OWNED_AUCTIONS_UPDATED -> GetOwnedAuctions().
-- It tells the ledger what you have listed (units and auctions per item) and the names your sales
-- mail will use (an item link's name -> its itemID). Posting (AUCTION_HOUSE_AUCTION_CREATED) and
-- cancelling (AUCTION_CANCELED) ask again. Sold auctions (waiting for their mail) aren't listed.
-- diag.owned keeps the raw fields of a few auctions: is buyoutAmount per unit or per auction?

local Owned = {}
ns.Owned = Owned
local events = ns.events

local DELAY = 1              -- seconds after the AH opens, a post or a cancel
local SAMPLES = 6
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
    local listed, samples, sold = {}, {}, 0
    for _, a in ipairs(list) do
        local itemID = a.itemKey and a.itemKey.itemID
        if itemID and not ns.IsSecret(itemID) then
            if a.status == Enum.AuctionStatus.Sold then
                sold = sold + 1
            else
                local entry = listed[itemID] or { q = 0, n = 0 }
                entry.q, entry.n = entry.q + (a.quantity or 0), entry.n + 1
                listed[itemID] = entry
            end
            local name = NameOf(a.itemLink)
            if name then ns.Ledger.LearnName(name, itemID) end
            if #samples < SAMPLES then
                samples[#samples + 1] = { itemID = itemID, quantity = a.quantity, buyoutAmount = a.buyoutAmount,
                    bidAmount = a.bidAmount, status = a.status, timeLeftSeconds = a.timeLeftSeconds }
            end
        end
    end
    local now = GetServerTime()
    ns.Ledger.SetListed(listed, now)
    local d = Diag()
    d.t, d.auctions, d.sold, d.samples = now, #list, sold, samples
    d.full = C_AuctionHouse.HasFullOwnedAuctionResults()
    ns.Fire("LEDGER_CHANGED")
end

function events:OWNED_AUCTIONS_UPDATED()
    Read()
end

function events:AUCTION_HOUSE_AUCTION_CREATED()
    if ns.ahOpen then Schedule() end
end

function events:AUCTION_CANCELED()
    if ns.ahOpen then Schedule() end
end

-- /bf diag: the last look at your auctions.
function Owned.PrintDiag()
    local d = ns.db and ns.db.diag.owned
    if not d or not d.t then return end
    local first = d.samples and d.samples[1]
    ns.Print(string.format("your auctions %s: %d (%d sold, waiting for the mail), full %s, %d queries%s",
        date("%H:%M:%S", d.t), d.auctions or 0, d.sold or 0, tostring(d.full), d.queries or 0,
        first and string.format("; first: item %s x%s, buyout %s, bid %s, %s s left", tostring(first.itemID),
            tostring(first.quantity), tostring(first.buyoutAmount), tostring(first.bidAmount),
            tostring(first.timeLeftSeconds)) or ""))
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
