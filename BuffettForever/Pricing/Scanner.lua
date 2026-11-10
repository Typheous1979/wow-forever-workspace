local addonName, ns = ...

-- Auction House full scan (wowf-addon-dev auction-house.md):
--   Scanner.Start() -> C_AuctionHouse.ReplicateItems() -> the first REPLICATE_ITEM_LIST_UPDATE
--   -> read every row, time-sliced (needs the AH open; closing it aborts and stores nothing)
--   -> price each item, time-sliced (finishes even if the AH closes) -> PriceDB.Record.
-- States: idle -> waiting -> reading -> pricing -> idle. Inside the full-scan cooldown the
-- server ignores the request (no event at all [F-121]), so no data within REPLICATE_TIMEOUT
-- seconds ends the scan with a message; data that arrives late is still read. The server can
-- also ignore a request outside the cooldown (twice on 70888, after a restart [F-143]):
-- Scanner.Bound keeps those out of the cooldown estimate.
-- The scanner also fills BuffettForeverDB.diag, which answers the open AH probes in CLAUDE.md:
-- the replicate index base, the cooldown (every request, with bounds derived from them),
-- scan timings, rows missing info, the market-key inputs per character, SupportsCopperValues,
-- and which reagents are commodities. While reading, it names the items of sales waiting in the
-- ledger for an ID (sales mail gives the item's name only). Pricing leaves out your own auctions
-- (from the auctions list read at this visit, Pricing/Owned.lua; Econ.ExcludeOwn), and notes the
-- listings priced below what a vendor pays (Pricing/Flips.lua).

local L = ns.L
local Scanner = {}
ns.Scanner = Scanner
local events = ns.events

local BUDGET_MS = 8            -- work per frame
local OWN_MAX_AGE = 30 * 60    -- your auctions list is used to clean a scan only when it's this fresh
local REPLICATE_TIMEOUT = 60   -- seconds to wait for REPLICATE_ITEM_LIST_UPDATE
local COOLDOWN_GUESS = 15 * 60 -- retail's full-scan cooldown; 14.6 to 18.7 min on the beta [F-121]
local SILENT_CAP = 30 * 60     -- no data this long after the last data isn't the cooldown [F-143]
local DIAG_KEEP = 20           -- entries kept in each diagnostics list
-- Linen Cloth, Copper Ore, Copper Bar, Peacebloom, Light Leather: are reagents commodities?
local PROBE_ITEMS = { 2589, 2770, 2840, 2447, 2318 }

local state = "idle"
local scan            -- the scan in progress
local lateRequest     -- a timed-out request whose data may still arrive
local notice          -- why the last scan failed, shown in the status line until the next scan

local function NowMs()
    return debugprofilestop()
end

-- ---------------------------------------------------------------- cooldown bounds (pure: the selftest runs them)

-- A lower bound the evidence rules out: at or past what a request with data proved (atMost), or past
-- SILENT_CAP. Only bounds saved before Scanner.Bound's rule hold one (live 70888: over 33,764 s, at most 6,991 s).
local function ImpossibleOver(cooldown)
    local over = cooldown.over
    return over ~= nil and (over >= SILENT_CAP or (cooldown.atMost ~= nil and over >= cooldown.atMost))
end

-- What a request's outcome, `since` seconds after the last data, says about the cooldown (over < cooldown <=
-- atMost). Data proves cooldown <= since, and rules out a lower bound at or past it. No data counts as the
-- cooldown only below atMost and SILENT_CAP: the server also ignores requests for other reasons [F-143], and
-- those are counted as unanswered instead. Returns "data", "cooldown" or "unanswered" (nil: no last data yet).
function Scanner.Bound(cooldown, since, gotData)
    if type(since) ~= "number" then return nil end
    if gotData then
        cooldown.atMost = math.min(cooldown.atMost or since, since)
        if ImpossibleOver(cooldown) then cooldown.over = nil end
        return "data"
    end
    if since < math.min(cooldown.atMost or SILENT_CAP, SILENT_CAP) then
        cooldown.over = math.max(cooldown.over or 0, since)
        return "cooldown"
    end
    cooldown.unanswered = (cooldown.unanswered or 0) + 1
    return "unanswered"
end

-- The cooldown estimate in seconds: retail's 15 min, kept inside the bounds (over < cooldown <= atMost).
function Scanner.Estimate(cooldown)
    local over = not ImpossibleOver(cooldown) and cooldown.over or 0
    return math.min(cooldown.atMost or math.huge, math.max(COOLDOWN_GUESS, over))
end

-- ---------------------------------------------------------------- diagnostics

-- Cooldown bounds from the request log: for logs written before diag.cooldown existed, and for bounds
-- saved before Scanner.Bound's rule. Requests it doesn't count as the cooldown are marked unanswered.
local function SeedCooldown(diag)
    local cooldown, lastData = {}, nil
    for _, r in ipairs(diag.requests) do
        if lastData and r.t and r.data ~= nil then
            if Scanner.Bound(cooldown, r.t - lastData, r.data) == "unanswered" then r.unanswered = true end
        end
        if r.data then lastData = r.t end
    end
    diag.cooldown = cooldown
    diag.lastData = diag.lastData or lastData
end

local function Diag()
    local diag = ns.db.diag
    diag.requests = diag.requests or {}
    diag.scans = diag.scans or {}
    diag.chars = diag.chars or {}
    diag.probeItems = diag.probeItems or {}
    if not diag.cooldown or (ImpossibleOver(diag.cooldown) and not ns.readOnlyDB) then SeedCooldown(diag) end
    return diag
end

local function Push(list, entry)
    list[#list + 1] = entry
    while #list > DIAG_KEEP do table.remove(list, 1) end
end

local function SetNotice(text)
    notice = text
    if text then ns.Print(text) end
end

local function Progress(phase, done, total)
    ns.Fire("SCAN_PROGRESS", phase, done, total)
end

-- A request's outcome narrows the cooldown (Scanner.Bound); data also starts the next one.
local function NoteOutcome(request, gotData)
    local diag = Diag()
    if Scanner.Bound(diag.cooldown, request.sinceData, gotData) == "unanswered" then request.unanswered = true end
    if gotData then diag.lastData = request.t end
end

-- A timed-out request whose data never came: count it as "no data" once we stop waiting.
local function ExpireLateRequest()
    if lateRequest then
        NoteOutcome(lateRequest, false)
        lateRequest = nil
    end
end

-- ---------------------------------------------------------------- probes at the auctioneer

-- isCommodity for the probe reagents; item-key info can arrive later (ITEM_KEY_ITEM_INFO_RECEIVED).
local function ProbeCommodity(itemID)
    local entry = Diag().probeItems[itemID] or {}
    Diag().probeItems[itemID] = entry
    local info = C_AuctionHouse.GetItemKeyInfo(C_AuctionHouse.MakeItemKey(itemID))
    if info then
        entry.isCommodity = info.isCommodity
        entry.name = info.itemName
        entry.pending = nil
    else
        entry.pending = true
    end
end

local function ProbeAuctioneer()
    if ns.readOnlyDB then return end
    local diag = Diag()
    local key = ns.CharKey()
    if key then
        diag.chars[key] = {
            t = GetServerTime(),
            realm = GetRealmName(),
            normalized = GetNormalizedRealmName(),
            faction = UnitFactionGroup("player"),
            hardcore = C_GameRules.IsHardcoreActive(),
            marketKey = ns.PriceDB.MarketKey(),
        }
    end
    diag.copperValues = C_AuctionHouse.SupportsCopperValues()
    diag.build = select(2, GetBuildInfo())
    for _, itemID in ipairs(PROBE_ITEMS) do ProbeCommodity(itemID) end
end

function events:ITEM_KEY_ITEM_INFO_RECEIVED(itemID)
    local entry = ns.db and ns.db.diag.probeItems and ns.db.diag.probeItems[itemID]
    if entry and entry.pending and not ns.readOnlyDB then ProbeCommodity(itemID) end
end

-- ---------------------------------------------------------------- full scan

-- One row's interesting returns, or nil when the call errors.
local function PeekRow(i)
    local ok, _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID, hasAllInfo =
        pcall(C_AuctionHouse.GetReplicateItemInfo, i)
    if not ok then return nil end
    local linkOK, link = pcall(C_AuctionHouse.GetReplicateItemLink, i)
    return { itemID = itemID, count = count, buyout = buyout, hasAllInfo = hasAllInfo,
             link = linkOK and link or nil }
end

local function IsRow(row)
    return row ~= nil and type(row.itemID) == "number" and row.itemID > 0
end

-- Rows are 0..n-1 on 70425; past the end a row reads itemID 0, count -1 [F-121]. Look at rows
-- 0 and n and read only the range that holds data, so the loop works with either base, and
-- the answer stays in the diagnostics.
local function FindRange(n)
    local row0, rowN = PeekRow(0), PeekRow(n)
    local has0, hasN = IsRow(row0), IsRow(rowN)
    local first = has0 and 0 or 1
    local last = hasN and n or n - 1
    local base = "?"
    if n > 0 and has0 and not hasN then base = 0 end
    if n > 0 and hasN and not has0 then base = 1 end
    Diag().replicate = { n = n, row0 = row0 or "error", rowN = rowN or "error", base = base,
                         t = GetServerTime() }
    return first, last
end

local Finish

local function PriceStep(s)
    if scan ~= s or state ~= "pricing" then return end
    local stop = NowMs() + BUDGET_MS
    local ids, acc, own = s.ids, s.acc, s.own
    while s.j <= #ids and NowMs() < stop do
        local itemID = ids[s.j]
        local listings = acc[itemID]
        if own and own[itemID] then
            -- your own auctions aren't the market: you'd neither buy them nor compete with them
            local removed
            listings, removed = ns.Econ.ExcludeOwn(listings, own[itemID])
            s.ownRemoved = s.ownRemoved + removed
        end
        ns.PriceDB.Record(itemID, listings, s.t)
        local flip, unknown = ns.Flips.Find(itemID, listings)   -- listings below what a vendor pays
        if flip then
            s.flips[#s.flips + 1] = flip
        elseif unknown then
            s.flipsUnknown = s.flipsUnknown + 1
            s.unknown[itemID] = listings   -- looked at again once the item's data loads
        end
        s.j = s.j + 1
    end
    Progress("pricing", s.j - 1, #ids)
    if s.j <= #ids then
        C_Timer.After(0, function() PriceStep(s) end)
    else
        Finish(s)
    end
end

local function StartPricing(s)
    s.readMs = math.floor(NowMs() - s.readStarted)
    s.pricingStarted = NowMs()
    s.own, s.ownRemoved = ns.Ledger.OwnLevels(OWN_MAX_AGE), 0
    s.flips, s.flipsUnknown, s.unknown = {}, 0, {}
    state = "pricing"
    s.ids, s.j = {}, 1
    for itemID in pairs(s.acc) do s.ids[#s.ids + 1] = itemID end
    PriceStep(s)
end

local function ReadStep(s)
    if scan ~= s or state ~= "reading" then return end
    if not ns.ahOpen then return end   -- AH_CLOSED aborts the scan
    local stop = NowMs() + BUDGET_MS
    local GetInfo = C_AuctionHouse.GetReplicateItemInfo
    local acc, waiting = s.acc, s.waiting
    while s.i <= s.last and NowMs() < stop do
        local name, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID, hasAllInfo = GetInfo(s.i)
        s.rows = s.rows + 1
        if not itemID or itemID == 0 then
            s.noItemID = s.noItemID + 1
        else
            if not hasAllInfo then s.missing = s.missing + 1 end
            -- a sale in your mail named this item before its ID was known (Pricing/Ledger.lua)
            if waiting and name and waiting[name] then ns.Ledger.LearnName(name, itemID) end
            if count and count > 0 and buyout and buyout > 0 then
                local t = acc[itemID]
                if not t then
                    t = {}
                    acc[itemID] = t
                    s.items = s.items + 1
                end
                t[#t + 1] = buyout / count
                t[#t + 1] = count
            else
                s.bidOnly = s.bidOnly + 1
            end
        end
        s.i = s.i + 1
    end
    Progress("reading", s.rows, s.total)
    if s.i <= s.last then
        C_Timer.After(0, function() ReadStep(s) end)
    else
        StartPricing(s)
    end
end

-- Quantities seen for the probe reagents in this scan.
local function NoteProbeQuantities(s)
    for _, itemID in ipairs(PROBE_ITEMS) do
        local entry = Diag().probeItems[itemID] or {}
        Diag().probeItems[itemID] = entry
        local listings, qty = s.acc[itemID], 0
        if listings then
            for k = 2, #listings, 2 do qty = qty + listings[k] end
        end
        entry.qtySeen = qty
        entry.auctions = listings and #listings / 2 or 0
        entry.t = s.t
    end
end

Finish = function(s)
    state = "idle"
    scan = nil
    local summary = {
        t = s.t, n = s.n, rows = s.rows, items = s.items, missing = s.missing, noItemID = s.noItemID,
        bidOnly = s.bidOnly, waitMs = s.request.waitMs, readMs = s.readMs,
        pricingMs = s.pricingStarted and math.floor(NowMs() - s.pricingStarted) or 0,
        totalMs = math.floor(NowMs() - s.started), late = s.late, updates = s.updates,
        ownRemoved = s.ownRemoved, ownChecked = s.own ~= nil,
        flips = s.flips and #s.flips or nil, flipsUnknown = s.flipsUnknown,
    }
    if s.items == 0 then summary.empty = true end
    Push(Diag().scans, summary)
    NoteProbeQuantities(s)
    if s.items == 0 then
        if s.n == 0 then
            SetNotice(L["The Auction House is empty: nothing to price."])
        else
            SetNotice(string.format(L["No buyout prices in %s listings (bid-only): nothing to price."],
                BreakUpLargeNumbers(s.n)))
        end
    else
        ns.PriceDB.NoteScan(s.t, s.items, s.rows - s.noItemID)
        ns.PriceDB.NoteFlips(s.t, s.flips)
        ns.Flips.Recheck(s.t, s.flips, s.unknown, summary)
        SetNotice(nil)
        ns.Print(string.format(L["Scan complete: %s items from %s listings in %.1f s."],
            BreakUpLargeNumbers(s.items), BreakUpLargeNumbers(s.rows - s.noItemID), summary.totalMs / 1000))
    end
    ns.Fire("SCAN_DONE", summary)
end

local function BeginRead(s)
    local n = C_AuctionHouse.GetNumReplicateItems() or 0
    s.n = n
    s.request.data = true
    s.request.n = n
    if not s.late then s.request.waitMs = math.floor(NowMs() - s.started) end
    NoteOutcome(s.request, true)
    s.first, s.last = FindRange(n)
    s.i, s.total = s.first, math.max(0, s.last - s.first + 1)
    s.acc, s.rows, s.items, s.missing, s.noItemID, s.bidOnly = {}, 0, 0, 0, 0, 0
    s.waiting = ns.Ledger.PendingNames()
    s.readStarted = NowMs()
    state = "reading"
    ReadStep(s)
end

local function OnTimeout(s)
    if scan ~= s or state ~= "waiting" then return end
    s.request.data = false
    s.request.waitMs = REPLICATE_TIMEOUT * 1000
    lateRequest = s.request   -- NoteOutcome waits: the data may still come
    state = "idle"
    scan = nil
    Push(Diag().scans, { t = s.t, timeout = true })
    if s.request.early then
        SetNotice(string.format(L["No data came back from the Auction House in %d s (probably the full-scan cooldown). Try again later."],
            REPLICATE_TIMEOUT))
    else
        -- the cooldown should have been over: the server ignored it for another reason [F-143]
        SetNotice(string.format(L["The Auction House didn't answer in %d s, though its full-scan cooldown should be over. Try again in about %d min."],
            REPLICATE_TIMEOUT, math.floor(COOLDOWN_GUESS / 60)))
    end
    ns.Fire("SCAN_DONE", { timeout = true })
end

function events:REPLICATE_ITEM_LIST_UPDATE()
    if not ns.db then return end
    if state == "waiting" and scan then
        if scan.timer then scan.timer:Cancel() end
        BeginRead(scan)
    elseif state == "idle" and lateRequest and ns.ahOpen and not ns.readOnlyDB then
        -- Our request timed out but its data came after all: read it now.
        local request = lateRequest
        lateRequest = nil
        request.lateSeconds = GetServerTime() - request.t
        scan = { t = GetServerTime(), started = NowMs(), request = request, late = true }
        SetNotice(nil)
        ns.Print(L["Auction data arrived late; reading it now."])
        BeginRead(scan)
    elseif state ~= "idle" then
        -- Fires again, thousands of times, as item data for the rows being read arrives [F-121].
        local diag = Diag()
        diag.extraUpdates = (diag.extraUpdates or 0) + 1
        if scan then scan.updates = (scan.updates or 0) + 1 end
    else
        -- Someone else's ReplicateItems, or an update after our scan finished.
        local diag = Diag()
        diag.unrequestedUpdates = (diag.unrequestedUpdates or 0) + 1
    end
end

-- ---------------------------------------------------------------- public

function Scanner.State()
    return state
end

function Scanner.IsBusy()
    return state ~= "idle"
end

-- Seconds until a full scan is likely to get data again (0: now), and the cooldown estimate (Scanner.Estimate).
function Scanner.CooldownLeft()
    if not ns.db then return 0, COOLDOWN_GUESS end
    local diag = Diag()
    local estimate = Scanner.Estimate(diag.cooldown)
    if not diag.lastData then return 0, estimate end
    return math.max(0, estimate - (GetServerTime() - diag.lastData)), estimate
end

-- "Next full scan in about 12 min." while the cooldown probably runs, else nil.
function Scanner.CooldownHint()
    local left, estimate = Scanner.CooldownLeft()
    if left <= 0 then return nil end
    return string.format(L["Next full scan in about %d min (the Auction House allows one about every %d min)."],
        math.ceil(left / 60), math.floor(estimate / 60 + 0.5))
end

-- Whether a full scan can start now, and why not.
function Scanner.CanScan()
    if not ns.db then return false, L["Still loading."] end
    if ns.readOnlyDB then return false, L["The saved data is read-only: scanning is paused."] end
    if not ns.ahOpen then return false, L["Open the Auction House to scan."] end
    if state ~= "idle" then return false, L["A scan is already running."] end
    return true
end

function Scanner.Start()
    local ok, why = Scanner.CanScan()
    if not ok then
        ns.Print(why)
        return false
    end
    ExpireLateRequest()   -- first: a timed-out request's outcome can move the estimate
    local hint = Scanner.CooldownHint()
    if hint then ns.Print(hint .. " " .. L["Trying anyway; it will probably get no data."]) end
    local now = GetServerTime()
    local diag = Diag()
    local request = { t = now, early = hint and true or nil }   -- early: inside the estimated cooldown
    if diag.lastRequest then request.sincePrev = now - diag.lastRequest end
    if diag.lastData then request.sinceData = now - diag.lastData end
    diag.lastRequest = now
    Push(diag.requests, request)
    SetNotice(nil)
    local s = { t = now, started = NowMs(), request = request }
    scan = s
    state = "waiting"
    s.timer = C_Timer.NewTimer(REPLICATE_TIMEOUT, function() OnTimeout(s) end)
    Progress("waiting")
    C_AuctionHouse.ReplicateItems()
    return true
end

-- One line for the window's status line and the AH button's tooltip.
function Scanner.StatusText()
    if ns.svTooLarge then
        return L["The saved price data is too large: the game won't save it this session. Scanning is paused."]
    end
    if ns.readOnlyDB then return L["The saved data is read-only: scanning is paused."] end
    if state == "waiting" then return L["Waiting for the Auction House to send its listings..."] end
    if state == "reading" and scan then
        local pct = scan.total > 0 and math.floor(scan.rows * 100 / scan.total) or 100
        return string.format(L["Reading listings: %s / %s (%d%%)"], BreakUpLargeNumbers(scan.rows),
            BreakUpLargeNumbers(scan.total), pct)
    end
    if state == "pricing" and scan then
        return string.format(L["Pricing items: %s / %s"], BreakUpLargeNumbers(scan.j - 1), BreakUpLargeNumbers(#scan.ids))
    end
    local text
    local count, last = ns.PriceDB.Summary()
    if count > 0 and last then
        text = string.format(L["%s items priced. Last full scan %s ago."], BreakUpLargeNumbers(count),
            ns.FormatAge(GetServerTime() - last.t))
    elseif count > 0 then
        text = string.format(L["%s items priced."], BreakUpLargeNumbers(count))
    elseif ns.ahOpen then
        text = L["No auction data yet."]
    else
        text = L["No auction data yet. Open the Auction House to scan."]
    end
    if notice then
        text = text .. "  " .. notice
    elseif ns.ahOpen then
        local hint = Scanner.CooldownHint()
        if hint then text = text .. "  " .. hint end
    end
    return text
end

-- /bf diag: a chat summary of BuffettForeverDB.diag (read the full table with savedvars.py).
function Scanner.PrintDiag()
    if not ns.db then return end
    local diag = Diag()
    local function out(fmt, ...) ns.Print(string.format(fmt, ...)) end
    out("build %s, copper values %s, market key %s", tostring(diag.build), tostring(diag.copperValues),
        tostring(ns.PriceDB.MarketKey()))
    local r = diag.replicate
    if r then
        local function row(x)
            if type(x) ~= "table" then return tostring(x) end
            return string.format("item %s x%s %s", tostring(x.itemID), tostring(x.count), tostring(x.link or "-"))
        end
        out("replicate: n %d, base %s; row 0: %s; row n: %s", r.n or -1, tostring(r.base), row(r.row0), row(r.rowN))
    end
    for i = math.max(1, #diag.requests - 4), #diag.requests do
        local q = diag.requests[i]
        out("request %s: %s s after the last data, data %s, wait %s ms, n %s%s%s%s", date("%H:%M:%S", q.t),
            tostring(q.sinceData or "-"), tostring(q.data), tostring(q.waitMs or "-"), tostring(q.n or "-"),
            q.lateSeconds and (", late " .. q.lateSeconds .. " s") or "", q.aborted and ", AH closed" or "",
            q.unanswered and ", unanswered outside the cooldown" or "")
    end
    local cooldown = diag.cooldown
    out("cooldown: over %s s, at most %s s, %d unanswered outside it; next scan in about %d s",
        tostring(cooldown.over or "?"), tostring(cooldown.atMost or "?"), cooldown.unanswered or 0,
        (Scanner.CooldownLeft()))
    local s = diag.scans[#diag.scans]
    if s then
        if s.timeout then
            out("last scan: timed out")
        elseif s.aborted then
            out("last scan: stopped while %s", tostring(s.aborted))
        else
            out("last scan: %d rows, %d items, %d missing info, %d bid-only, %d without itemID; wait %s ms, read %s ms, price %s ms; %s extra updates; %s of your units left out; %s flips (%s items' vendor price unknown; once loaded, %s more flips, %s still unknown)",
                s.rows or 0, s.items or 0, s.missing or 0, s.bidOnly or 0, s.noItemID or 0,
                tostring(s.waitMs), tostring(s.readMs), tostring(s.pricingMs), tostring(s.updates or 0),
                s.ownChecked and tostring(s.ownRemoved or 0) or "none", tostring(s.flips or "-"),
                tostring(s.flipsUnknown or "-"), tostring(s.lateFlips or "-"), tostring(s.stillUnknown or "-"))
        end
    end
    for _, itemID in ipairs(PROBE_ITEMS) do
        local p = diag.probeItems[itemID]
        if p then
            out("%d %s: commodity %s, %s seen in %s auctions", itemID, tostring(p.name or "?"),
                tostring(p.isCommodity), tostring(p.qtySeen or "-"), tostring(p.auctions or "-"))
        end
    end
    if diag.extraUpdates or diag.unrequestedUpdates then
        out("replicate updates: %d extra during a scan, %d unrequested", diag.extraUpdates or 0,
            diag.unrequestedUpdates or 0)
    end
end

-- ---------------------------------------------------------------- self test

-- /bf selftest: the cooldown bounds on the beta's measurements and on live 70888's unanswered requests.
function Scanner.SelfTest(report)
    local passed, failed = 0, 0
    local function check(name, ok, detail)
        if ok then passed = passed + 1 else failed = failed + 1 end
        report(name, ok, detail)
    end
    -- Bound over a copy of `start`, one {since, gotData} step at a time: the bounds, what each step was taken for,
    -- and the estimate.
    local function run(start, steps)
        local cooldown, taken = {}, {}
        for k, v in pairs(start) do cooldown[k] = v end
        for _, step in ipairs(steps) do
            taken[#taken + 1] = tostring(Scanner.Bound(cooldown, step[1], step[2]))
        end
        return cooldown, table.concat(taken, ", "), Scanner.Estimate(cooldown)
    end
    -- the beta (70425): no data 877 s after the last data, data 1,120 s after it [F-121]
    local c, taken, estimate = run({}, { { 877, false }, { 1120, true } })
    check("COOLDOWN-BOUNDS", c.over == 877 and c.atMost == 1120 and estimate == 900,
        string.format("no data at 877 s, data at 1,120 s: %s; over %s, at most %s; estimate %d s", taken,
            tostring(c.over), tostring(c.atMost), estimate))
    -- live 70888: data 6,991 s after the last data, then nothing 33,689 and 33,764 s after it [F-143]
    c, taken, estimate = run({ atMost = 6991 }, { { 33689, false }, { 33764, false } })
    check("COOLDOWN-SILENT", c.over == nil and c.unanswered == 2 and estimate == 900,
        string.format("no data 9.4 h after the last data, once data came after 6,991 s: %s; over %s; estimate %d s, "
            .. "not 6,991 s (117 min)", taken, tostring(c.over), estimate))
    -- the bounds 1.0.1 saved from them
    estimate = Scanner.Estimate({ atMost = 6991, over = 33764 })
    check("COOLDOWN-SAVED", estimate == 900,
        string.format("saved over 33,764 s, at most 6,991 s: estimate %d s", estimate))
    -- nothing proven yet: no data at 2 h isn't the cooldown, no data at 1,000 s is
    c, taken, estimate = run({}, { { 7200, false }, { 1000, false } })
    check("COOLDOWN-CAP", c.over == 1000 and c.unanswered == 1 and estimate == 1000,
        string.format("no data at 2 h, then at 1,000 s: %s; over %s; estimate %d s", taken, tostring(c.over), estimate))
    -- data inside an earlier lower bound: that bound wasn't the cooldown
    c, taken, estimate = run({ over = 1500 }, { { 1200, true } })
    check("COOLDOWN-HEAL", c.over == nil and c.atMost == 1200 and estimate == 900,
        string.format("over 1,500 s, then data at 1,200 s: %s; over %s, at most %s; estimate %d s", taken,
            tostring(c.over), tostring(c.atMost), estimate))
    return passed, failed
end

ns.On("AH_OPEN", function()
    ProbeAuctioneer()
    ns.Fire("SCAN_PROGRESS")
end)

ns.On("AH_CLOSED", function()
    ExpireLateRequest()
    if scan and (state == "waiting" or state == "reading") then
        if scan.timer then scan.timer:Cancel() end
        if state == "waiting" then
            scan.request.waitMs = math.floor(NowMs() - scan.started)
            scan.request.aborted = true
        end
        Push(Diag().scans, { t = scan.t, aborted = state })
        state = "idle"
        scan = nil
        SetNotice(L["Scan stopped: the Auction House closed."])
        ns.Fire("SCAN_DONE", { aborted = true })
    else
        ns.Fire("SCAN_PROGRESS")
    end
end)

ns.eventFrame:RegisterEvent("REPLICATE_ITEM_LIST_UPDATE")
ns.eventFrame:RegisterEvent("ITEM_KEY_ITEM_INFO_RECEIVED")
