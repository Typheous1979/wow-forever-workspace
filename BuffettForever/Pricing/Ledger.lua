local addonName, ns = ...

-- Your own Auction House results per market, from your mail (Pricing/Mail.lua) and your auctions
-- list (Pricing/Owned.lua). The mail is per character, the market isn't, so your characters on one
-- market share a ledger:
--   BuffettForeverDB.markets[marketKey].ledger = {
--     items = { [itemID] = { s = units sold, e = expired, c = cancelled, bid = sale totals,
--                            cut = house cuts, b = units bought, paid = paid totals, t = last change } },
--     s, e, c = units sold, expired and cancelled over all items (sales not filed yet included),
--     cut = { bid = sale totals, cut = cut totals, n = seller invoices },     -- the measured house cut
--     names = { [item name] = itemID },          -- sales mail names the item but carries no ID
--     pending = { [item name] = { s, bid, cut, t } },   -- sales whose item isn't identified yet
--     seen = { [mail key] = { expiry time, ... } },     -- mails counted already (Mail.Reconcile)
--     listed = { [itemID] = { q = units, n = auctions, levels = { unit price, qty, ... } } },
--     listedAt = time,                                                      -- your active auctions
--   }
-- Item names are learned from your auctions list, from items that come back in the mail, and from the
-- next full scan (Scanner); a pending sale is filed the moment its name is known.
-- Sale chance (Econ.ItemSaleChance): the item's sold / (sold + expired), pulled toward your rate over
-- all items, which starts at settings.saleChance. Cancelled auctions count neither way.
-- Every change fires LEDGER_CHANGED.

local L = ns.L
local Ledger = {}
ns.Ledger = Ledger

local TOP = 10                  -- items listed by /bf ledger

local function NewBook()
    return { items = {}, s = 0, e = 0, c = 0, cut = { bid = 0, cut = 0, n = 0 }, names = {}, pending = {},
             seen = {}, listed = {} }
end

-- This market's ledger; created on demand when create is true (never while the data is read-only).
function Ledger.Book(create)
    local market = ns.PriceDB.Market(create and not ns.readOnlyDB)
    if not market then return nil end
    if not market.ledger and create and not ns.readOnlyDB then market.ledger = NewBook() end
    return market.ledger
end

local function Item(book, itemID)
    local item = book.items[itemID]
    if not item then
        item = { s = 0, e = 0, c = 0, bid = 0, cut = 0, b = 0, paid = 0 }
        book.items[itemID] = item
    end
    return item
end

-- Sales of `name` belong to itemID from now on; a sale waiting for that name is filed. Returns true
-- when one was.
local function Learn(book, name, itemID)
    if type(name) ~= "string" or name == "" or not itemID then return false end
    book.names[name] = itemID
    local waiting = book.pending[name]
    if not waiting then return false end
    book.pending[name] = nil
    local item = Item(book, itemID)
    item.s, item.bid, item.cut = item.s + waiting.s, item.bid + waiting.bid, item.cut + waiting.cut
    item.t = math.max(item.t or 0, waiting.t or 0)
    return true
end

local function Sale(book, name, units, bid, cut, t)
    book.s = book.s + units
    book.cut.bid, book.cut.cut, book.cut.n = book.cut.bid + bid, book.cut.cut + cut, book.cut.n + 1
    local itemID = book.names[name]
    if itemID then
        local item = Item(book, itemID)
        item.s, item.bid, item.cut, item.t = item.s + units, item.bid + bid, item.cut + cut, t
    else
        local waiting = book.pending[name] or { s = 0, bid = 0, cut = 0 }
        waiting.s, waiting.bid, waiting.cut, waiting.t = waiting.s + units, waiting.bid + bid, waiting.cut + cut, t
        book.pending[name] = waiting
    end
end

local function Return(book, itemID, name, units, kind, t)
    if not itemID then return end
    Learn(book, name, itemID)
    local item = Item(book, itemID)
    if kind == "cancelled" then
        item.c, book.c = item.c + units, book.c + units
    else
        item.e, book.e = item.e + units, book.e + units
    end
    item.t = t
end

local function Bought(book, itemID, name, units, paid, t)
    itemID = itemID or book.names[name]
    if not itemID then return end
    Learn(book, name, itemID)
    local item = Item(book, itemID)
    item.b, item.paid, item.t = item.b + units, item.paid + paid, t
end

-- File one counted mail (Pricing/Mail.lua): m = { kind, name, itemID, units, bid, cut, paid, t }.
-- kind: "sold", "expired", "returned" (an AH return the subject didn't name: counted as expired),
-- "cancelled" or "bought".
function Ledger.File(book, m)
    if m.kind == "sold" then
        Sale(book, m.name, m.units, m.bid or 0, m.cut or 0, m.t)
    elseif m.kind == "expired" or m.kind == "returned" then
        Return(book, m.itemID, m.name, m.units, "expired", m.t)
    elseif m.kind == "cancelled" then
        Return(book, m.itemID, m.name, m.units, "cancelled", m.t)
    elseif m.kind == "bought" then
        Bought(book, m.itemID, m.name, m.units, m.paid or 0, m.t)
    end
end

-- From your auctions list or a full scan: the item behind a name.
function Ledger.LearnName(name, itemID)
    if ns.readOnlyDB or ns.IsSecret(name) then return end
    local book = Ledger.Book(true)
    if book and Learn(book, name, itemID) then ns.Fire("LEDGER_CHANGED") end
end

-- Sales waiting for their item's name ({ [name] = ... }), or nil when none are.
function Ledger.PendingNames()
    local book = Ledger.Book()
    if book and next(book.pending) then return book.pending end
    return nil
end

function Ledger.Item(itemID)
    local book = Ledger.Book()
    return book and book.items[itemID] or nil
end

-- The item's sale chance, its own sold and expired units, and your rate over all items.
-- itemID nil: no record of its own.
function Ledger.SaleChance(itemID, book)
    local prior = ns.db and ns.db.settings.saleChance or 0.5
    book = book or Ledger.Book()
    local item = book and itemID and book.items[itemID]
    local s, e = item and item.s or 0, item and item.e or 0
    local p, market = ns.Econ.ItemSaleChance(s, e, book and book.s or 0, book and book.e or 0, prior)
    return p, s, e, market
end

-- Your rate over all items in the market: the sale chance of an item without a record of its own.
function Ledger.MarketSaleChance(book)
    local _, _, _, market = Ledger.SaleChance(nil, book)
    return market
end

-- The house cut: measured from your sales mail once there are enough sales, else the setting.
-- Returns rate, measured (true/false), seller invoices so far.
function Ledger.Cut()
    local default = ns.db and ns.db.settings.cut or 0.05
    local book = Ledger.Book()
    if not book then return default, false, 0 end
    local c = book.cut
    local rate = ns.Econ.MeasuredCut(c.cut, c.bid, c.n)
    if rate then return rate, true, c.n end
    return default, false, c.n
end

-- Your active auctions at the auctioneer (Pricing/Owned.lua): { [itemID] = { q, n } }.
function Ledger.SetListed(listed, t)
    if ns.readOnlyDB then return end
    local book = Ledger.Book(true)
    if not book then return end
    book.listed, book.listedAt = listed, t
end

-- Your active auctions' unit prices per item, { [itemID] = { unit price, qty, ... } }, when the last look
-- at them is under maxAge seconds old (a full scan leaves them out of the market); else nil.
function Ledger.OwnLevels(maxAge)
    local book = Ledger.Book()
    if not book or not book.listedAt or GetServerTime() - book.listedAt > maxAge then return nil end
    local levels = {}
    for itemID, entry in pairs(book.listed or {}) do
        if entry.levels and #entry.levels > 0 then levels[itemID] = entry.levels end
    end
    return levels
end

-- Your active auctions of an item at the last look: units, auctions, seconds since; nil when none.
function Ledger.Listed(itemID)
    local book = Ledger.Book()
    local entry = book and book.listed and book.listed[itemID]
    if not entry then return nil end
    return entry.q, entry.n, GetServerTime() - (book.listedAt or 0)
end

local function Pct(x)
    return string.format("%d%%", math.floor(x * 100 + 0.5))
end

-- /bf ledger: the cut, your sell-through and the items with the most results.
function Ledger.PrintSummary()
    local key = ns.PriceDB.MarketKey() or "?"
    local book = Ledger.Book()
    local rate, measured, invoices = Ledger.Cut()
    if measured then
        ns.Print(string.format(L["%s: the AH cut is %.1f%%, measured from %d of your sales."], key, rate * 100, invoices))
    else
        ns.Print(string.format(L["%s: the AH cut counts as %s (the default) until %d of your sales worth 1g in all measure it; %d so far."],
            key, Pct(rate), ns.Econ.CUT_MIN_SALES, invoices))
    end
    if book and book.listedAt then
        local auctions = 0
        for _, entry in pairs(book.listed) do auctions = auctions + entry.n end
        ns.Print(string.format(L["%d of your auctions were listed at the last look, %s ago."], auctions,
            ns.FormatAge(GetServerTime() - book.listedAt)))
    end
    if not book or book.s + book.e + book.c == 0 then
        ns.Print(L["No auction results yet: open a mailbox after an auction sells, expires or is cancelled."])
        return
    end
    ns.Print(string.format(L["Your auctions: %d units sold, %d expired, %d cancelled. Sale chance %s for items without a record of their own."],
        book.s, book.e, book.c, Pct(Ledger.MarketSaleChance(book))))
    local ids = {}
    for itemID, item in pairs(book.items) do
        if item.s + item.e + item.c > 0 then ids[#ids + 1] = itemID end
    end
    local function results(item) return item.s + item.e + item.c end
    table.sort(ids, function(a, b)
        local x, y = results(book.items[a]), results(book.items[b])
        if x ~= y then return x > y end
        return a < b
    end)
    while #ids > TOP do table.remove(ids) end
    ns.Items.Load(ids, function()
        for _, itemID in ipairs(ids) do
            local item = book.items[itemID]
            local average = item.s > 0 and (" " .. string.format(L["at %s each"], ns.Money.Format(item.bid / item.s))) or ""
            ns.Print(string.format(L["  %s: %d sold%s, %d expired, %d cancelled; sale chance %s"], ns.Items.Link(itemID),
                item.s, average, item.e, item.c, Pct((Ledger.SaleChance(itemID, book)))))
        end
        for name, waiting in pairs(book.pending) do
            ns.Print(string.format(L["  %s: %d sold, filed once the item is identified (your auctions list or the next full scan)."],
                name, waiting.s))
        end
    end)
end

-- ---------------------------------------------------------------- self test

-- Filing on a scratch book: a sale before its name is known, a return that names it, a cancel.
function Ledger.SelfTest(report)
    local passed, failed = 0, 0
    local function check(name, ok, detail)
        if ok then passed = passed + 1 else failed = failed + 1 end
        report(name, ok, detail)
    end
    local book = NewBook()
    Ledger.File(book, { kind = "sold", name = "Bolt of Linen Cloth", units = 2, bid = 6000, cut = 300, t = 1 })
    check("LEDGER-PENDING", book.pending["Bolt of Linen Cloth"] ~= nil and book.s == 2 and book.cut.n == 1
        and book.cut.bid == 6000 and next(book.items) == nil, "a sale of an unidentified item waits for its name")
    Ledger.File(book, { kind = "expired", name = "Bolt of Linen Cloth", itemID = 2996, units = 3, t = 2 })
    local item = book.items[2996]
    check("LEDGER-FILED", item ~= nil and item.s == 2 and item.e == 3 and item.bid == 6000
        and book.pending["Bolt of Linen Cloth"] == nil and book.names["Bolt of Linen Cloth"] == 2996,
        "the expired mail names the item, and the waiting sale is filed under it")
    Ledger.File(book, { kind = "cancelled", name = "Bolt of Linen Cloth", itemID = 2996, units = 4, t = 3 })
    Ledger.File(book, { kind = "sold", name = "Bolt of Linen Cloth", units = 1, bid = 2900, cut = 145, t = 4 })
    local p, s, e = Ledger.SaleChance(2996, book)
    local expected = ns.Econ.ItemSaleChance(3, 3, 3, 3, ns.db and ns.db.settings.saleChance or 0.5)
    check("LEDGER-CHANCE", s == 3 and e == 3 and item.c == 4 and math.abs(p - expected) < 1e-9,
        string.format("3 sold, 3 expired, 4 cancelled (not counted): sale chance %s", tostring(p)))
    return passed, failed
end
