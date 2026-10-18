local addonName, ns = ...

-- Auction House mail, read at the mailbox without opening anything, files the sales ledger
-- (Pricing/Ledger.lua; auction-house.md "Sales mail"):
-- - seller invoice (GetInboxInvoiceInfo type "seller"): units sold, the sale total and the house cut;
--   a "seller_temp_invoice" (money still on its way) waits for the real invoice;
-- - buyer invoice: units bought and the price paid, with the item attached;
-- - an expired or cancelled auction: the subject matches Blizzard's AUCTION_EXPIRED_MAIL_SUBJECT or
--   AUCTION_REMOVED_MAIL_SUBJECT, and the items come back attached (GetInboxItem). If the game has no
--   such strings, items attached to a mail from the Auction House's sender (learned from its
--   invoices) count as expired: a cancel counted as an expiry only lowers the sale chance.
-- GetInboxText is never called (it opens a mail, marking it read). No player names are kept.
-- Mails carry no ID. Each one is keyed by kind, item and amount, and told apart from an identical one
-- by its days left and expiry time (now + days left), stored per mail (Mail.Reconcile):
-- - "days left" is a snapshot of the last inbox refresh, and the refresh is rate-limited, so a
--   reopened mailbox can show the old list [F-130]: an exact days-left match is the same mail;
-- - after a refresh, a mail matches the nearest stored expiry time within TOLERANCE seconds;
-- - identical mails count once each. Returned items are keyed without their count, so taking some of
--   them doesn't make the mail look new.
-- The inbox is read on MAIL_SHOW and every MAIL_INBOX_UPDATE while the mailbox is open, so "Open All"
-- can't take a mail unseen.
-- Each read also counts the units of each item in won-auction mail (Mail.Won) and hands them to
-- Pricing/Collect.lua with the read before it in this visit: a drop there is what BuffettForever bought
-- leaving the mailbox. That part runs even when the account file is read-only (it's per character).
-- Bus: MAILBOX_OPEN, MAILBOX_READ (after each read) and MAILBOX_CLOSED.
-- diag.mail answers the open probes: do the subject strings exist, who sends AH mail, how precise is
-- "days left", does reading an unread invoice mark it read, and (fresh) is the list new at an open.

local Mail = {}
ns.Mail = Mail
local events = ns.events

local TOLERANCE = 300        -- seconds: one mail's expiry time, read after two refreshes
local SAME_SNAPSHOT = 1e-7   -- days (under 0.01 s): the same days-left value, as saved and reloaded
local KEEP = 86400           -- a stored mail is forgotten this long after it expired
local SAMPLES = 12           -- AH mails kept in diag.mail.samples
local ATTACHMENTS = 16       -- attachment slots (Blizzard's ATTACHMENTS_MAX_RECEIVE)
local SUBJECTS = {           -- Blizzard's subject formats, by kind
    expired = "AUCTION_EXPIRED_MAIL_SUBJECT",
    cancelled = "AUCTION_REMOVED_MAIL_SUBJECT",
    outbid = "AUCTION_OUTBID_MAIL_SUBJECT",
    sold = "AUCTION_SOLD_MAIL_SUBJECT",
    won = "AUCTION_WON_MAIL_SUBJECT",
}
local SUBJECT_ORDER = { "expired", "cancelled", "outbid", "sold", "won" }
local COUNTED = { sold = true, expired = true, returned = true, cancelled = true, bought = true }

local FRESH_KEEP = 5         -- mailbox opens kept in diag.mail.fresh

local mailOpen = false
local patterns               -- kind = Lua pattern, built on first use
local lastWon                -- this visit's previous count of units in won-auction mail; nil at an open

-- "Auction expired: %s" -> "^Auction expired: (.+)$"; nil unless fmt has exactly one %s.
function Mail.SubjectPattern(fmt)
    if type(fmt) ~= "string" then return nil end
    local escaped = fmt:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
    local pattern, count = escaped:gsub("%%%%s", "(.+)")
    if count ~= 1 then return nil end
    return "^" .. pattern .. "$"
end

local function Patterns()
    if patterns then return patterns end
    patterns = {}
    for kind, global in pairs(SUBJECTS) do
        local fmt = _G[global]
        if type(fmt) == "string" then patterns[kind] = Mail.SubjectPattern(fmt) end
    end
    return patterns
end

-- Which mails of this read are new. seen = { [key] = { { e = expiry, dl = days left }, ... } } is
-- updated (a bare number is an expiry stored by 0.5.0); mails = { { key, expires, daysLeft } }.
-- Each mail first takes an unused stored entry with the same days left (the same snapshot), else the
-- nearest unused expiry within TOLERANCE (a refresh; the entry takes the new values); the unmatched
-- ones are new and get stored. Entries more than KEEP past expiry are forgotten. Returns the new mails
-- and the largest expiry gap among the mails matched by time.
function Mail.Reconcile(seen, mails, now)
    local byKey = {}
    for _, m in ipairs(mails) do
        local list = byKey[m.key]
        if not list then
            list = {}
            byKey[m.key] = list
        end
        list[#list + 1] = m
    end
    local new, drift = {}, 0
    for key, list in pairs(byKey) do
        local stored = seen[key] or {}
        seen[key] = stored
        for j, entry in ipairs(stored) do
            if type(entry) == "number" then stored[j] = { e = entry } end
        end
        local used, rest = {}, {}
        table.sort(list, function(a, b) return a.expires < b.expires end)
        for _, m in ipairs(list) do
            local same
            for j, entry in ipairs(stored) do
                if not used[j] and entry.dl and m.daysLeft and math.abs(entry.dl - m.daysLeft) < SAME_SNAPSHOT then
                    same = j
                    break
                end
            end
            if same then used[same] = true else rest[#rest + 1] = m end
        end
        for _, m in ipairs(rest) do
            local best, bestGap
            for j, entry in ipairs(stored) do
                local gap = math.abs(entry.e - m.expires)
                if not used[j] and gap <= TOLERANCE and (not bestGap or gap < bestGap) then best, bestGap = j, gap end
            end
            if best then
                used[best] = true
                stored[best] = { e = m.expires, dl = m.daysLeft }
                if bestGap > drift then drift = bestGap end
            else
                stored[#stored + 1] = { e = m.expires, dl = m.daysLeft }
                used[#stored] = true
                new[#new + 1] = m
            end
        end
    end
    for key, stored in pairs(seen) do
        for j = #stored, 1, -1 do
            local entry = stored[j]
            local e = type(entry) == "number" and entry or entry.e
            if e < now - KEEP then table.remove(stored, j) end
        end
        if #stored == 0 then seen[key] = nil end
    end
    return new, drift
end

local function Diag()
    local diag = ns.db.diag
    diag.mail = diag.mail or {}
    local d = diag.mail
    d.kinds = d.kinds or {}      -- AH mails by kind in the last read
    d.filed = d.filed or {}      -- mails filed into the ledger, by kind
    d.samples = d.samples or {}
    d.senders = d.senders or {}  -- who sends Auction House invoices
    d.markedRead = d.markedRead or { checked = 0, flipped = 0 }
    if not d.subjects then
        d.subjects = {}
        for kind, global in pairs(SUBJECTS) do
            local fmt = _G[global]
            d.subjects[kind] = type(fmt) == "string" and fmt or false
        end
    end
    return d
end

-- The first attached item and how many of it came back.
local function Attachments(i)
    local itemID, name, units = nil, nil, 0
    for a = 1, ATTACHMENTS do
        local attachedName, attachedID, _, count = GetInboxItem(i, a)
        if attachedID and not ns.IsSecret(attachedID) then
            if not itemID then itemID, name = attachedID, attachedName end
            if attachedID == itemID then units = units + (count or 1) end
        end
    end
    return itemID, name, units
end

local function Secret(...)
    for k = 1, select("#", ...) do
        if ns.IsSecret((select(k, ...))) then return true end
    end
    return false
end

-- Mail i as { kind, key, expires, name, itemID, units, bid, cut, paid, ... }, or nil when it isn't
-- Auction House mail (or can't be read). Mail that isn't an invoice must also be system mail (no
-- reply possible, not returned, not from a GM), so a player's mail titled "Auction expired: ..."
-- doesn't count.
local function Classify(i, now, d)
    local _, _, sender, subject, money, _, daysLeft, itemCount, wasRead, wasReturned, _, canReply, isGM =
        GetInboxHeaderInfo(i)
    if Secret(sender, subject, money, daysLeft, itemCount) or type(daysLeft) ~= "number" then return nil end
    local invoiceType, itemName, _, bid, _, deposit, consignment, _, _, _, count = GetInboxInvoiceInfo(i)
    if Secret(invoiceType, itemName, bid, deposit, consignment, count) then return nil end
    local m = { t = now, expires = now + daysLeft * 86400 }
    local invoice = invoiceType == "seller" or invoiceType == "seller_temp_invoice" or invoiceType == "buyer"
    if invoice and (type(itemName) ~= "string" or itemName == "") then
        m.kind, m.key = "unnamed", "unnamed|" .. invoiceType    -- an invoice without its item: not counted
    elseif invoiceType == "seller" or invoiceType == "seller_temp_invoice" then
        m.kind = invoiceType == "seller" and "sold" or "pending"
        m.name, m.units, m.bid, m.cut, m.deposit = itemName, count or 1, bid or 0, consignment or 0, deposit
        m.key = string.format("%s|%s|%d|%.0f", m.kind, itemName, m.units, m.bid)
    elseif invoiceType == "buyer" then
        m.kind, m.name, m.units, m.paid = "bought", itemName, count or 1, bid or 0
        m.itemID = Attachments(i)
        m.key = string.format("bought|%s|%d|%.0f", itemName, m.units, m.paid)
    else
        if canReply or wasReturned or isGM then return nil end
        local p, kind = Patterns(), nil
        if type(subject) == "string" then
            for _, k in ipairs(SUBJECT_ORDER) do
                if p[k] and string.match(subject, p[k]) then
                    kind = k
                    break
                end
            end
        end
        if not kind and not p.expired and (itemCount or 0) > 0 and type(sender) == "string" and d.senders[sender] then
            kind = "returned"
        end
        if not kind then return nil end
        -- A sale or a purchase whose invoice didn't read: seen in diag.mail, never counted.
        if kind == "sold" or kind == "won" then kind = kind .. "NoInvoice" end
        m.kind = kind
        if kind == "expired" or kind == "cancelled" or kind == "returned" then
            m.itemID, m.name, m.units = Attachments(i)
            if not m.itemID then return nil end   -- the items were taken already: nothing to count
        end
        m.key = string.format("%s|%s|%s", kind, tostring(m.itemID or "-"), tostring(subject))
    end
    if type(sender) == "string" then d.senders[sender] = true end   -- invoices and subject-matched system mail
    if wasRead == false then
        -- Did reading it mark it read?
        d.markedRead.checked = d.markedRead.checked + 1
        if select(9, GetInboxHeaderInfo(i)) == true then d.markedRead.flipped = d.markedRead.flipped + 1 end
    end
    m.sender, m.subject, m.money, m.wasRead, m.daysLeft, m.itemCount = sender, subject, money, wasRead, daysLeft, itemCount
    return m
end

local function Sample(d, m)
    for _, s in ipairs(d.samples) do
        if s.key == m.key then return end
    end
    if #d.samples >= SAMPLES then return end
    d.samples[#d.samples + 1] = {
        key = m.key, kind = m.kind, itemID = m.itemID, units = m.units, bid = m.bid, cut = m.cut, deposit = m.deposit,
        paid = m.paid, money = m.money, daysLeft = m.daysLeft, itemCount = m.itemCount, wasRead = m.wasRead,
        sender = m.sender, subject = m.subject, t = m.t,
    }
end

-- Mail i's attachments into out when it's won-auction mail: a buyer invoice, or the AUCTION_WON subject on
-- system mail (not a reply, not returned, not from a GM; the mail's COD and GM flags are kept anyway, so
-- Collect can refuse them).
local function WonAttachments(i, out)
    local _, _, _, subject, _, cod, _, itemCount, _, wasReturned, _, canReply, isGM = GetInboxHeaderInfo(i)
    if Secret(subject, cod, itemCount, isGM) or (itemCount or 0) == 0 then return end
    local invoiceType = GetInboxInvoiceInfo(i)
    local won = not ns.IsSecret(invoiceType) and invoiceType == "buyer"
    if not won and type(subject) == "string" and not canReply and not wasReturned and not isGM then
        local p = Patterns()
        won = p.won ~= nil and string.match(subject, p.won) ~= nil
    end
    if not won then return end
    for a = 1, ATTACHMENTS do
        local _, itemID, _, count = GetInboxItem(i, a)
        if itemID and not ns.IsSecret(itemID) and not ns.IsSecret(count) then
            out[#out + 1] = { index = i, attachment = a, itemID = itemID, units = count or 1, cod = cod or 0,
                              gm = isGM == true, won = true }
        end
    end
end

-- Every attachment of every won-auction mail in the open mailbox:
-- { { index, attachment, itemID, units, cod, gm, won = true } } (Pricing/Collect.lua takes from these).
function Mail.Won()
    local out = {}
    if not mailOpen then return out end
    for i = 1, GetInboxNumItems() or 0 do pcall(WonAttachments, i, out) end
    return out
end

function Mail.IsOpen()
    return mailOpen
end

-- { [itemID] = units } over won-auction mail.
local function WonUnits(list)
    local units = {}
    for _, m in ipairs(list) do units[m.itemID] = (units[m.itemID] or 0) + m.units end
    return units
end

-- The sales ledger's part of a read (the account file).
local function FileLedger()
    local book = ns.Ledger.Book(true)
    if not book then return end
    local now = GetServerTime()
    local d = Diag()
    local count = GetInboxNumItems() or 0
    local mails, kinds = {}, {}
    for i = 1, count do
        local ok, m = pcall(Classify, i, now, d)
        if not ok then
            d.errors, d.lastError = (d.errors or 0) + 1, tostring(m)
            m = nil
        end
        if m then
            kinds[m.kind] = (kinds[m.kind] or 0) + 1
            if COUNTED[m.kind] then mails[#mails + 1] = m end
            Sample(d, m)
        end
    end
    local new, drift = Mail.Reconcile(book.seen, mails, now)
    for _, m in ipairs(new) do
        ns.Ledger.File(book, m)
        d.filed[m.kind] = (d.filed[m.kind] or 0) + 1
    end
    d.t, d.reads, d.inbox, d.kinds = now, (d.reads or 0) + 1, count, kinds
    if drift > (d.refreshGap or 0) then d.refreshGap = drift end
    if #new > 0 then ns.Fire("LEDGER_CHANGED") end
end

local function ReadInbox()
    if not mailOpen then return end
    if ns.charDB then
        local won = WonUnits(Mail.Won())
        ns.Collect.MailRead(lastWon, won)
        lastWon = won
    end
    if ns.db and not ns.readOnlyDB then FileLedger() end
    ns.Fire("MAILBOX_READ")
end

-- Read again now (Collect, after a take).
function Mail.ReadNow()
    ReadInbox()
end

-- At an open: is the list already new (HasNewMail, CanCheckInbox, the counts)? For a later "the mail is gone"
-- rule; today the first read of a visit is never taken as the mail being gone.
local function Fresh()
    if not ns.db or ns.readOnlyDB then return end
    local d = Diag()
    local can, wait = C_Mail.CanCheckInbox()
    local shown, total = GetInboxNumItems()
    d.fresh = d.fresh or {}
    table.insert(d.fresh, 1, { t = GetServerTime(), hasNew = HasNewMail() and true or false, canCheck = can, wait = wait,
                               shown = shown, total = total })
    while #d.fresh > FRESH_KEEP do table.remove(d.fresh) end
end

function events:MAIL_SHOW()
    mailOpen, lastWon = true, nil
    Fresh()
    ReadInbox()
    ns.Fire("MAILBOX_OPEN")
end

function events:MAIL_INBOX_UPDATE()
    ReadInbox()
end

function events:MAIL_CLOSED()
    if not mailOpen then return end
    mailOpen, lastWon = false, nil
    ns.Fire("MAILBOX_CLOSED")
end

local function Counts(t)
    local parts = {}
    for kind, n in pairs(t or {}) do parts[#parts + 1] = kind .. " " .. n end
    table.sort(parts)
    return #parts > 0 and table.concat(parts, ", ") or "none"
end

-- /bf diag: the last mailbox read.
function Mail.PrintDiag()
    local d = ns.db and ns.db.diag.mail
    if not d or not d.t then return end
    local found = {}
    for _, kind in ipairs(SUBJECT_ORDER) do
        found[#found + 1] = kind .. (d.subjects and d.subjects[kind] and " yes" or " no")
    end
    ns.Print(string.format("mail %s: %d in the inbox, AH mail: %s; filed: %s; subject strings: %s",
        date("%H:%M:%S", d.t), d.inbox or 0, Counts(d.kinds), Counts(d.filed), table.concat(found, ", ")))
    local senders = 0
    for _ in pairs(d.senders or {}) do senders = senders + 1 end
    ns.Print(string.format("mail: %d reads, largest expiry gap after a refresh %s s, %d AH sender(s), unread checked %d, marked read %d",
        d.reads or 0, tostring(d.refreshGap or 0), senders, d.markedRead and d.markedRead.checked or 0,
        d.markedRead and d.markedRead.flipped or 0))
    if d.errors then ns.Print(string.format("mail: %d mails couldn't be read; last error: %s", d.errors, tostring(d.lastError))) end
end

-- ---------------------------------------------------------------- self test

function Mail.SelfTest(report)
    local passed, failed = 0, 0
    local function check(name, ok, detail)
        if ok then passed = passed + 1 else failed = failed + 1 end
        report(name, ok, detail)
    end
    local p = Mail.SubjectPattern("Auction expired: %s")
    check("MAIL-SUBJECT", p == "^Auction expired: (.+)$" and string.match("Auction expired: Linen Cloth", p) == "Linen Cloth"
        and Mail.SubjectPattern("Outbid on %s (100%)") == "^Outbid on (.+) %(100%%%)$" and Mail.SubjectPattern("no args") == nil,
        "subject formats become anchored patterns with magic characters escaped")

    -- Mail A arrives at t0; its twin B 5 s later; A is taken; the mailbox reopens an hour later on the
    -- cached list; then a refresh shows B and a third identical mail C. days left = 30 days minus the
    -- age at the refresh; a read computes expires = read time + days left.
    local key, t0, day = "sold|Bolt of Linen Cloth|1|2900", 1000000, 86400
    local function mail(age, readAt)
        local daysLeft = 30 - age / day
        return { key = key, daysLeft = daysLeft, expires = readAt + daysLeft * day }
    end
    local seen = {}
    local new = Mail.Reconcile(seen, { mail(0, t0) }, t0)
    local again = Mail.Reconcile(seen, { mail(0, t0) }, t0 + 60)   -- the same snapshot read a minute later
    check("MAIL-ONCE", #new == 1 and #again == 0, "a mail read twice counts once")
    new = Mail.Reconcile(seen, { mail(120, t0 + 120), mail(115, t0 + 120) }, t0 + 120)
    check("MAIL-TWINS", #new == 1, string.format("an identical second mail counts too: %d new", #new))
    new = Mail.Reconcile(seen, { mail(175, t0 + 180) }, t0 + 180)
    check("MAIL-TAKEN", #new == 0, "taking one of the two adds nothing")
    new = Mail.Reconcile(seen, { mail(175, t0 + 3780) }, t0 + 3780)
    check("MAIL-SNAPSHOT", #new == 0, "the cached list an hour later (its times look an hour off) adds nothing")
    local drift
    new, drift = Mail.Reconcile(seen, { mail(3795, t0 + 3800), mail(100, t0 + 3800) }, t0 + 3800)
    check("MAIL-LATER", #new == 1 and drift < 1, string.format("after a refresh B matches (gap %s s) and C is new (%d)",
        tostring(drift), #new))
    new = Mail.Reconcile(seen, {}, t0 + 30 * day + 3700 + day + 1)
    check("MAIL-FORGET", #new == 0 and seen[key] == nil, "mails are forgotten a day after they expire")
    local old = { [key] = { t0 + 30 * day } }   -- an expiry stored by 0.5.0
    new = Mail.Reconcile(old, { mail(60, t0 + 60) }, t0 + 60)
    check("MAIL-OLD-FORMAT", #new == 0 and type(old[key][1]) == "table", "entries stored by 0.5.0 still match")
    return passed, failed
end

ns.eventFrame:RegisterEvent("MAIL_SHOW")
ns.eventFrame:RegisterEvent("MAIL_INBOX_UPDATE")
ns.eventFrame:RegisterEvent("MAIL_CLOSED")
