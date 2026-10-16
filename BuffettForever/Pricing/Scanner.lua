local addonName, ns = ...

-- Auction House full scan (wowf-addon-dev auction-house.md):
--   Scanner.Start() -> C_AuctionHouse.ReplicateItems() -> the first REPLICATE_ITEM_LIST_UPDATE
--   -> read every row, time-sliced (needs the AH open; closing it aborts and stores nothing)
--   -> price each item, time-sliced (finishes even if the AH closes) -> PriceDB.Record.
-- States: idle -> waiting -> reading -> pricing -> idle. Inside the full-scan cooldown the
-- server ignores the request (no event at all [F-121]), so no data within REPLICATE_TIMEOUT
-- seconds ends the scan with a message; data that arrives late is still read.
-- The scanner also fills BuffettForeverDB.diag, which answers the open AH probes in CLAUDE.md:
-- the replicate index base, the cooldown (every request, with bounds derived from them),
-- scan timings, rows missing info, the market-key inputs per character, SupportsCopperValues,
-- and which reagents are commodities.

local L = ns.L
local Scanner = {}
ns.Scanner = Scanner
local events = ns.events

local BUDGET_MS = 8            -- work per frame
local REPLICATE_TIMEOUT = 60   -- seconds to wait for REPLICATE_ITEM_LIST_UPDATE
local COOLDOWN_GUESS = 15 * 60 -- retail's full-scan cooldown; Forever's is over 2 min [F-121]
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

-- Cooldown bounds from the request log, for logs written before diag.cooldown existed:
-- a request that got data after s seconds proves cooldown <= s; one that got none, > s.
local function SeedCooldown(diag)
    local cooldown, lastData = {}, nil
    for _, r in ipairs(diag.requests) do
        if lastData and r.t and r.data ~= nil then
            local since = r.t - lastData
            if r.data then
                cooldown.atMost = math.min(cooldown.atMost or since, since)
            else
                cooldown.over = math.max(cooldown.over or 0, since)
            end
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
    if not diag.cooldown then SeedCooldown(diag) end
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

-- A request's outcome narrows the cooldown: data after s seconds means cooldown <= s.
local function NoteOutcome(request, gotData)
    local diag = Diag()
    local cooldown = diag.cooldown
    local since = request.sinceData
    if since then
        if gotData then
            cooldown.atMost = math.min(cooldown.atMost or since, since)
        else
            cooldown.over = math.max(cooldown.over or 0, since)
        end
    end
    if gotData then diag.lastData = request.t end
end

-- A timed-out request whose data never came: count it as "no data" once we stop waiting.
local function ExpireLateRequest()
    if lateRequest then
        NoteOutcome(lateRequest, false)
        lateRequest = nil
    end
end

-- "First Surname" (names are two-part on Forever [F-080]); nil if unreadable.
local function CharKey()
    local first, surname = UnitFullName("player")
    if not first or ns.IsSecret(first) or ns.IsSecret(surname) then return nil end
    if surname and surname ~= "" then return first .. " " .. surname end
    return first
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
    local key = CharKey()
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
    local ids, acc = s.ids, s.acc
    while s.j <= #ids and NowMs() < stop do
        local itemID = ids[s.j]
        ns.PriceDB.Record(itemID, acc[itemID], s.t)
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
    local acc = s.acc
    while s.i <= s.last and NowMs() < stop do
        local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID, hasAllInfo = GetInfo(s.i)
        s.rows = s.rows + 1
        if not itemID or itemID == 0 then
            s.noItemID = s.noItemID + 1
        else
            if not hasAllInfo then s.missing = s.missing + 1 end
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
    SetNotice(string.format(L["No data came back from the Auction House in %d s (probably the full-scan cooldown). Try again later."],
        REPLICATE_TIMEOUT))
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

-- Seconds until a full scan is likely to get data again (0: now), and the cooldown estimate:
-- retail's 15 min, kept inside the measured bounds (over < cooldown <= atMost).
function Scanner.CooldownLeft()
    if not ns.db then return 0, COOLDOWN_GUESS end
    local diag = Diag()
    local cooldown = diag.cooldown
    local estimate = math.min(cooldown.atMost or math.huge, math.max(COOLDOWN_GUESS, cooldown.over or 0))
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
    local hint = Scanner.CooldownHint()
    if hint then ns.Print(hint .. " " .. L["Trying anyway; it will probably get no data."]) end
    ExpireLateRequest()
    local now = GetServerTime()
    local diag = Diag()
    local request = { t = now }
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
        out("request %s: %s s after the last data, data %s, wait %s ms, n %s%s%s", date("%H:%M:%S", q.t),
            tostring(q.sinceData or "-"), tostring(q.data), tostring(q.waitMs or "-"), tostring(q.n or "-"),
            q.lateSeconds and (", late " .. q.lateSeconds .. " s") or "", q.aborted and ", AH closed" or "")
    end
    local cooldown = diag.cooldown
    out("cooldown: over %s s, at most %s s; next scan in about %d s", tostring(cooldown.over or "?"),
        tostring(cooldown.atMost or "?"), (Scanner.CooldownLeft()))
    local s = diag.scans[#diag.scans]
    if s then
        if s.timeout then
            out("last scan: timed out")
        elseif s.aborted then
            out("last scan: stopped while %s", tostring(s.aborted))
        else
            out("last scan: %d rows, %d items, %d missing info, %d bid-only, %d without itemID; wait %s ms, read %s ms, price %s ms; %s extra updates",
                s.rows or 0, s.items or 0, s.missing or 0, s.bidOnly or 0, s.noItemID or 0,
                tostring(s.waitMs), tostring(s.readMs), tostring(s.pricingMs), tostring(s.updates or 0))
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
