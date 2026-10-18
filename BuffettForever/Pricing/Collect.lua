local addonName, ns = ...

-- What BuffettForever bought on the Auction House that's still in the mailbox, and collecting it (Justin,
-- 2026-10-18: a player would think the tray's purchases are in the bags). Forever mails every AH
-- purchase [F-132]; no call puts it in the bags.
-- - charDB.bought[itemID] = { q = units still in the mailbox, t = the last purchase, k = its kind }. Each
--   purchase adds (Pricing/Buy.lua: "ah" reagents, "flip" commodities, "auction" gear; never a probe).
--   Units leave only when, during one mailbox visit, that item's units in won-auction mail go down
--   (Mail.Won), so Collect, Blizzard's Open All and its own click all count. The first read of a visit
--   changes nothing: the inbox can be an old snapshot that misses new mail [F-130]. An entry goes after
--   30 days, as AH mail does.
-- - Collect (UI/MailButton.lua): one click takes one attachment of ours (TakeInboxItem, as Blizzard's
--   attachment click does), inside the click. Never chained from a timer the way Open All does: no addon
--   has taken mail on Forever yet. COD and GM mail are left alone, and so is an attachment larger than
--   what's ours of that item (someone else's purchase of the same thing).
-- Entries from before ({ q bought, base = bags and bank then, t }) become q = what the bags didn't show
-- yet, once, at the first BAGS_CHANGED after login. Fires BOUGHT_CHANGED (the ledger) and COLLECT_CHANGED
-- (a take). diag.collect keeps the last 20 takes; /bf mailtest lists what Collect would take, and why not.

local L = ns.L
local Collect = {}
ns.Collect = Collect
local events = ns.events

local KEEP = 20            -- takes kept in diag.collect
local MAIL_DAYS = 30       -- AH mail lasts 30 days [F-130]
local TICK = 0.1           -- seconds between checks of a take
local TAKE_TIMEOUT = 5     -- seconds for a take to show in the bags

local state = "ready"      -- "ready" or "taking"
local take                 -- the open take
local ticker, timer
local blocked              -- why taking mail is off for this session
local converted = false    -- the entries from before, converted once per session

local function Ledger()
    return ns.charDB and ns.charDB.bought
end

local function Changed()
    ns.Fire("COLLECT_CHANGED", state)
end

local function Name(itemID)
    return C_Item.GetItemNameByID(itemID) or ("item " .. itemID)
end

-- ---------------------------------------------------------------- pure helpers (the self-test runs them)

-- An entry from before (q bought, base = bags and bank at the purchase): the units the bags didn't show yet.
function Collect.LegacyPending(entry, count)
    return math.max(0, math.min(entry.q, entry.base + entry.q - count))
end

-- A purchase of n units of itemID (kind "ah", "flip" or "auction") at time now: added to its entry.
function Collect.RememberEntries(entries, itemID, n, kind, now)
    local entry = entries[itemID]
    if entry then
        entry.q, entry.t, entry.k = entry.q + n, now, kind
    else
        entry = { q = n, t = now, k = kind }
        entries[itemID] = entry
    end
    return entry
end

-- The drop rule. before: this visit's previous read ({ [itemID] = units in won-auction mail }), nil on the
-- visit's first read; now: this read. An item whose units went down was taken (a refreshed inbox only adds
-- mail), so what's ours of it is at most what's left. Returns whether anything changed.
function Collect.MailDrop(entries, before, now)
    if not before then return false end
    local changed = false
    for itemID, was in pairs(before) do
        local left, entry = now[itemID] or 0, entries[itemID]
        if entry and not entry.base and left < was and entry.q > left then
            entry.q, changed = left, true
            if left == 0 then entries[itemID] = nil end
        end
    end
    return changed
end

-- The next attachment to take from mails ({ { index, attachment, itemID, units, cod, gm, won } }), and its
-- place in the list: won-auction mail, no COD, not from a GM, of an item with units of ours in the mailbox
-- (ours[itemID] > 0) and no larger than those. A mail holding exactly what's ours comes first.
function Collect.Pick(mails, ours)
    local first, firstAt
    for i, m in ipairs(mails) do
        local mine = ours[m.itemID] or 0
        if m.won and (m.cod or 0) == 0 and not m.gm and mine > 0 and m.units <= mine then
            if m.units == mine then return m, i end
            if not first then first, firstAt = m, i end
        end
    end
    return first, firstAt
end

-- Every attachment Collect would take, in order: each pick takes its units off what's ours of that item, so
-- a second mail of the same item comes only while some of ours is left.
function Collect.Plan(mails, ours)
    local left, rest, plan = {}, {}, {}
    for itemID, q in pairs(ours) do left[itemID] = q end
    for i, m in ipairs(mails) do rest[i] = m end
    while true do
        local pick, at = Collect.Pick(rest, left)
        if not pick then break end
        plan[#plan + 1] = pick
        left[pick.itemID] = left[pick.itemID] - pick.units
        table.remove(rest, at)
    end
    return plan
end

-- ---------------------------------------------------------------- the ledger

-- The entries from before, once per session (the bags are loaded by the first BAGS_CHANGED).
local function ConvertLegacy()
    if converted then return end
    local ledger = Ledger()
    if not ledger then return end
    converted = true
    for itemID, entry in pairs(ledger) do
        if entry.base then
            local q = Collect.LegacyPending(entry, C_Item.GetItemCount(itemID, true) or 0)
            if q > 0 then
                entry.q, entry.base, entry.k = q, nil, entry.k or "ah"
            else
                ledger[itemID] = nil
            end
        end
    end
end

-- Units of itemID that BuffettForever bought and that are still in the mailbox.
function Collect.InMail(itemID)
    local entry = Ledger() and Ledger()[itemID]
    if not entry then return 0 end
    if entry.base then return Collect.LegacyPending(entry, C_Item.GetItemCount(itemID, true) or 0) end
    return entry.q or 0
end

-- { [itemID] = units still in the mailbox }
local function Ours()
    local out = {}
    for itemID in pairs(Ledger() or {}) do
        local q = Collect.InMail(itemID)
        if q > 0 then out[itemID] = q end
    end
    return out
end

-- What's still in the mailbox, by item: { { itemID, q, k } }, the most first.
function Collect.Summary()
    local list = {}
    for itemID, entry in pairs(Ledger() or {}) do
        local q = Collect.InMail(itemID)
        if q > 0 then list[#list + 1] = { itemID = itemID, q = q, k = entry.k } end
    end
    table.sort(list, function(a, b)
        if a.q ~= b.q then return a.q > b.q end
        return a.itemID < b.itemID
    end)
    return list
end

-- A purchase (Pricing/Buy.lua), before the tray is credited, so the tray's envelope shows at once.
function Collect.Remember(itemID, n, kind)
    local ledger = Ledger()
    if not ledger or not itemID or (n or 0) <= 0 then return end
    ConvertLegacy()
    Collect.RememberEntries(ledger, itemID, n, kind, GetServerTime())
    ns.Fire("BOUGHT_CHANGED")
end

-- ---------------------------------------------------------------- taking a mail

local function Step(text)
    if not take then return end
    take.steps[#take.steps + 1] = string.format("%.1fs %s", (debugprofilestop() - take.started) / 1000, text)
end

local function StopTimers()
    if ticker then
        ticker:Cancel()
        ticker = nil
    end
    if timer then
        timer:Cancel()
        timer = nil
    end
end

-- The attachments Collect would take now, in order.
function Collect.Pending()
    if not ns.Mail.IsOpen() then return {} end
    return Collect.Plan(ns.Mail.Won(), Ours())
end

function Collect.Count()
    return #Collect.Pending()
end

function Collect.State()
    return state, take
end

-- Close the take, keep it in diag.collect, and go back to ready.
local function Done(outcome)
    local rec = take
    if not rec then return end
    StopTimers()
    Step("outcome " .. outcome)
    rec.outcome, rec.started, rec.bagsAfter = outcome, nil, C_Item.GetItemCount(rec.itemID)
    take, state = nil, "ready"
    if ns.db and not ns.readOnlyDB then
        local list = ns.db.diag.collect or {}
        ns.db.diag.collect = list
        table.insert(list, 1, rec)
        while #list > KEEP do table.remove(list) end
    end
    if outcome == "taken" then
        -- Next frame, outside the inbox read that may have called this: read again (the drop rule, if the inbox
        -- didn't update by itself yet), then say what's left.
        C_Timer.After(0, function()
            ns.Mail.ReadNow()
            local left = Collect.Count()
            local text = left == 0 and L["Collected %d %s."] or left == 1 and L["Collected %d %s (1 more mail)."]
                or L["Collected %d %s (%d more mails)."]
            ns.Print(string.format(text, rec.units, ns.Items.Link(rec.itemID), left))
            Changed()
        end)
    end
    Changed()
end

-- Taken once the bags rise (MAIL_SUCCESS may say so first).
local function CheckTake()
    local rec = take
    if not rec or C_Mail.IsCommandPending() then return end
    local bags = C_Item.GetItemCount(rec.itemID)
    if bags > rec.bagsBefore then
        Step(string.format("bags +%d", bags - rec.bagsBefore))
        Done("taken")
    end
end

-- Blizzard's Open All, while it runs (its button is disabled only then).
local function OpenAllBusy()
    local button = InboxFrame and InboxFrame.OpenAllMail
    return button ~= nil and button:IsShown() and not button:IsEnabled()
end

-- Whether Collect can take a mail now, why not, and the attachment it would take.
function Collect.CanStart()
    if not ns.Mail.IsOpen() then return false, L["Open a mailbox to collect what you bought."] end
    if state ~= "ready" then return false, L["Taking a mail..."] end
    if blocked then return false, string.format(L["Forever blocked taking mail (%s): use Open All."], blocked) end
    if OpenAllBusy() then return false, L["Blizzard's Open All is running."] end
    if C_Mail.IsCommandPending() then return false, L["The mailbox is busy: a moment."] end
    local pick = Collect.Pending()[1]
    if not pick then return false, L["Nothing BuffettForever bought is in this mailbox."] end
    if (C_Container.CalculateTotalNumberOfFreeBagSlots() or 0) == 0 then return false, L["Your bags are full."] end
    return true, nil, pick
end

-- Runs inside the Collect click.
function Collect.Start()
    local ok, why, pick = Collect.CanStart()
    if not ok then
        ns.Print(why)
        return false
    end
    take = { t = GetServerTime(), build = select(2, GetBuildInfo()), itemID = pick.itemID, units = pick.units,
             index = pick.index, attachment = pick.attachment, ours = Collect.InMail(pick.itemID),
             mails = Collect.Count(), bagsBefore = C_Item.GetItemCount(pick.itemID), steps = {},
             started = debugprofilestop() }
    state = "taking"
    local called, err = pcall(TakeInboxItem, pick.index, pick.attachment)
    Step(called and string.format("TakeInboxItem(%d, %d) called", pick.index, pick.attachment)
        or ("TakeInboxItem error: " .. tostring(err)))
    if not called then
        ns.Print(L["The mail couldn't be taken (logged)."])
        Done("take error")
        return false
    end
    ticker = C_Timer.NewTicker(TICK, CheckTake)
    timer = C_Timer.NewTimer(TAKE_TIMEOUT, function()
        timer = nil
        if not take then return end
        ns.Print(string.format(L["%s didn't arrive in your bags: try again, or use Open All."], ns.Items.Link(take.itemID)))
        Done("no answer")
    end)
    Changed()
    return true
end

function events:MAIL_SUCCESS(itemID)
    if state ~= "taking" or not take then return end
    Step("MAIL_SUCCESS " .. tostring(itemID))
    if itemID == nil or itemID == take.itemID then Done("taken") end
end

function events:MAIL_FAILED(itemID)
    if state ~= "taking" or not take then return end
    Step("MAIL_FAILED " .. tostring(itemID))
    ns.Print(string.format(L["%s couldn't be taken from the mail: are your bags full?"], ns.Items.Link(take.itemID)))
    Done("failed")
end

-- Called by Pricing/Mail.lua after each read while the mailbox is open.
function Collect.MailRead(before, now)
    ConvertLegacy()
    local ledger = Ledger()
    if ledger and Collect.MailDrop(ledger, before, now) then ns.Fire("BOUGHT_CHANGED") end
    if state == "taking" then CheckTake() end
end

ns.On("MAILBOX_CLOSED", function()
    if take then Done("the mailbox closed") end
end)

ns.On("ACTION_BLOCKED", function(_, fn)
    if state ~= "taking" or not take then return end
    blocked = tostring(fn)
    Step("blocked " .. blocked)
    ns.Print(L["Forever blocked taking mail from an addon: use Open All."])
    Done("blocked")
end)

-- The entries from before, and anything older than its mail.
ns.On("BAGS_CHANGED", function()
    ConvertLegacy()
    local ledger = Ledger()
    if not ledger then return end
    local now, changed = GetServerTime(), false
    for itemID, entry in pairs(ledger) do
        if now - (entry.t or 0) > MAIL_DAYS * 86400 then
            ledger[itemID], changed = nil, true
        end
    end
    if changed then ns.Fire("BOUGHT_CHANGED") end
end)

-- ---------------------------------------------------------------- /bf mailtest and /bf diag

-- /bf mailtest: the won-auction mail in this mailbox, what Collect would take and in what order, and why
-- it leaves the rest. Kept in diag.mailtest.
function Collect.Probe()
    if not ns.Mail.IsOpen() then
        ns.Print(L["Open a mailbox first."])
        return
    end
    local mails, ours = ns.Mail.Won(), Ours()
    local plan, order = Collect.Plan(mails, ours), {}
    for i, m in ipairs(plan) do order[m] = i end
    local rows = {}
    ns.Print(string.format(L["Mail test: %d won-auction attachments; %d to collect."], #mails, #plan))
    for _, m in ipairs(mails) do
        local why
        if order[m] then
            why = string.format(L["takes it (%d of %d)"], order[m], #plan)
        elseif (m.cod or 0) > 0 then
            why = L["leaves it: COD"]
        elseif m.gm then
            why = L["leaves it: from a GM"]
        elseif (ours[m.itemID] or 0) == 0 then
            why = L["leaves it: not bought through BuffettForever"]
        else
            why = string.format(L["leaves it: more than the %d of ours"], ours[m.itemID])
        end
        ns.Print(string.format("  mail %d, slot %d: %d %s: %s", m.index, m.attachment, m.units, ns.Items.Link(m.itemID), why))
        rows[#rows + 1] = { index = m.index, attachment = m.attachment, itemID = m.itemID, units = m.units, cod = m.cod,
                            gm = m.gm, take = order[m] }
    end
    for itemID, q in pairs(ours) do ns.Print(string.format(L["  ours in the mail: %d %s"], q, Name(itemID))) end
    if ns.db and not ns.readOnlyDB then
        ns.db.diag.mailtest = { t = GetServerTime(), build = select(2, GetBuildInfo()), mails = rows, ours = ours,
                                inbox = GetInboxNumItems() }
    end
end

-- /bf diag: what's in the mail, and the last take.
function Collect.PrintDiag()
    local parts = {}
    for _, e in ipairs(Collect.Summary()) do parts[#parts + 1] = string.format("%d %s (%s)", e.q, Name(e.itemID), tostring(e.k)) end
    if #parts > 0 then ns.Print("in the mail: " .. table.concat(parts, ", ")) end
    local rec = ns.db and ns.db.diag.collect and ns.db.diag.collect[1]
    if rec then
        ns.Print(string.format("collect %s: %d x%d from mail %d slot %d: %s; bags %s -> %s; %s", date("%H:%M:%S", rec.t),
            rec.itemID, rec.units, rec.index, rec.attachment, tostring(rec.outcome), tostring(rec.bagsBefore),
            tostring(rec.bagsAfter), table.concat(rec.steps or {}, ", ")))
    end
    if blocked then ns.Print("collecting is off this session: " .. blocked) end
end

-- ---------------------------------------------------------------- self-test

function Collect.SelfTest(report)
    local passed, failed = 0, 0
    local function check(name, ok, detail)
        if ok then passed = passed + 1 else failed = failed + 1 end
        report(name, ok, detail)
    end
    local entries = {}
    Collect.RememberEntries(entries, 1, 3, "ah", 100)
    Collect.RememberEntries(entries, 1, 2, "ah", 200)
    Collect.RememberEntries(entries, 2, 1, "flip", 300)
    check("COLLECT-REMEMBER", entries[1].q == 5 and entries[1].t == 200 and entries[2].q == 1 and entries[2].k == "flip",
        "a purchase starts an entry, a second one adds to it, and a flip is kept as one")

    local ledger = { [1] = { q = 3 }, [2] = { q = 3 }, [3] = { q = 2 }, [4] = { q = 4 } }
    local first = Collect.MailDrop(ledger, nil, { [1] = 0 })
    local drop = Collect.MailDrop(ledger, { [1] = 3, [2] = 3, [3] = 2 }, { [1] = 1, [3] = 5 })
    check("MAIL-DROP", not first and drop and ledger[1].q == 1 and ledger[2] == nil and ledger[3].q == 2 and ledger[4].q == 4,
        "the first read of a visit changes nothing; 3 -> 1 leaves 1; 3 -> 0 clears it; a rise and an item not read stay")

    local P = Collect.LegacyPending
    local old = { q = 3, base = 6 }
    check("MAIL-LEGACY", P(old, 6) == 3 and P(old, 8) == 1 and P(old, 9) == 0 and P({ q = 12, base = 3 }, 1) == 12,
        "3 bought with 6 in the bags: 3 still out at 6, 1 at 8, none at 9; units used before (1 of 3 left) don't count")

    local mails = {
        { index = 1, attachment = 1, itemID = 10, units = 2, won = true, cod = 0 },
        { index = 2, attachment = 1, itemID = 10, units = 3, won = true, cod = 0 },
        { index = 3, attachment = 1, itemID = 20, units = 1, won = true, cod = 500 },
        { index = 4, attachment = 1, itemID = 20, units = 1, won = true, cod = 0, gm = true },
        { index = 5, attachment = 1, itemID = 30, units = 1, won = false, cod = 0 },
        { index = 6, attachment = 1, itemID = 40, units = 9, won = true, cod = 0 },
    }
    local pick = Collect.Pick(mails, { [10] = 3, [20] = 1, [30] = 1, [40] = 2 })
    local plan = Collect.Plan(mails, { [10] = 5 })
    local short = Collect.Plan(mails, { [10] = 2 })
    check("COLLECT-PICK", pick and pick.index == 2 and #plan == 2 and plan[1].index == 1 and plan[2].index == 2
        and #short == 1 and short[1].index == 1 and Collect.Pick(mails, { [20] = 1, [30] = 1, [40] = 2 }) == nil,
        "the mail with exactly ours first; then the rest while ours lasts; never COD, a GM's, other mail or more than ours")
    return passed, failed
end

ns.eventFrame:RegisterEvent("MAIL_SUCCESS")
ns.eventFrame:RegisterEvent("MAIL_FAILED")
