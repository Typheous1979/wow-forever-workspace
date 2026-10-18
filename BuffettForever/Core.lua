local addonName, ns = ...

-- BuffettForever — core: namespace helpers, SavedVariables lifecycle, event dispatch.
-- Target: WoW Forever (game type Camelot, interface 16001).

local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })
ns.L = L

local PREFIX = "|cff66ccff[BuffettForever]|r "

function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg)
end

-- Tiny internal message bus: ns.On("NAME", fn) listens, ns.Fire("NAME", ...) notifies.
local listeners = {}
function ns.On(message, fn)
    listeners[message] = listeners[message] or {}
    table.insert(listeners[message], fn)
end

function ns.Fire(message, ...)
    for _, fn in ipairs(listeners[message] or {}) do
        local ok, err = pcall(fn, ...)
        if not ok then geterrorhandler()(err) end
    end
end

-- Secret-value helpers: never do math, comparisons or print on secrets.
function ns.IsSecret(value)
    return type(issecretvalue) == "function" and issecretvalue(value) == true
end

function ns.SafeText(value, fallback)
    if value == nil or ns.IsSecret(value) then return fallback end
    return tostring(value)
end

-- The character's key for per-character data kept account-wide: "First Surname" (names are
-- two-part on Forever, never name-realm [F-080]); nil if the name can't be read.
function ns.CharKey()
    local first, surname = UnitFullName("player")
    if not first or ns.IsSecret(first) or ns.IsSecret(surname) then return nil end
    if surname and surname ~= "" then return first .. " " .. surname end
    return first
end

-- "<1 min", "12 min", "5 h", "3 d" for a number of seconds (reads well before "ago").
function ns.FormatAge(seconds)
    if type(seconds) ~= "number" then return "?" end
    if seconds < 60 then return L["<1 min"] end
    if seconds < 3600 then return string.format(L["%d min"], math.floor(seconds / 60)) end
    if seconds < 172800 then return string.format(L["%d h"], math.floor(seconds / 3600)) end
    return string.format(L["%d d"], math.floor(seconds / 86400))
end

-- Run protected-frame changes only out of combat.
local combatQueue = {}
function ns.RunOutOfCombat(fn)
    if InCombatLockdown() then
        combatQueue[#combatQueue + 1] = fn
    else
        fn()
    end
end

-- SavedVariables: defaults + forward-only migrations (never wipe player data).
local DB_VERSION = 3
local defaults = {
    minimap = { angle = 200, shown = true },   -- minimap button: degrees around the edge, visible
    settings = {                -- Blizzard's settings panel shows them all (Options.lua)
        historyDays = 14,       -- days of price history kept per item (pruned at login)
        -- Economics (wowf-economics defaults):
        cut = 0.05,             -- AH house cut until your sales mail measures it [F-122] (Pricing/Ledger.lua)
        measuredCut = true,     -- false: always `cut`, whatever your sales measure
        saleChance = 0.5,       -- chance a listing sells before it expires, until your sales say otherwise
        depositDuration = 0,    -- deposits at 1, 2, 3 = 2, 8, 24 hours; 0 = what the AH's sell frame remembers
        margin = 0.20,          -- margin of safety: AH over vendor, and the minimum ROI to recommend
        minProfit = 1000,       -- copper per craft (10s while leveling; the reference's 1g suits level 60)
        minGrade = "C",         -- weakest confidence grade a recommendation may rest on
        ownedPolicy = "opportunity",  -- owned materials at what they'd sell for ("free", "replacement")
        -- Selling on the AH (Pricing/Post.lua; Justin, 2026-10-18):
        postPrice = "match",          -- the cheapest listing by others ("1c", "1pct", "5pct", "10pct" under it)
        postVendorGuard = true,       -- refuse a price that nets less after the cut than a vendor pays
    },
    markets = {},   -- [marketKey] = { items = { [itemID] = price row }, scan = last full scan (Pricing/PriceDB.lua),
                    --                 ledger = your sales, returns and auctions (Pricing/Ledger.lua) }
    vendor = {},    -- [itemID] = { p = unit buy price, t, lim } (Pricing/Merchant.lua)
    deposits = {},  -- [itemID] = { k = "c" commodity or "i" gear, t } (Pricing/Deposits.lua)
    recipesKnown = {},  -- [charKey][recipeID] = true (Crafting/Harvest.lua)
    diag = {},      -- answers to the open probes: scanner, searches, merchant, harvest, mail, deposits, auctions
}
ns.DEFAULT_SETTINGS = defaults.settings   -- the settings panel's Defaults button (Options.lua)

local charDefaults = {
    window = {},   -- main window position (per character)
    tray = {},     -- reagent tray: { { itemID, qty }, ... } in slot order (Crafting/Tray.lua)
    bought = {},   -- [itemID] = { q still in the mailbox, t last purchase, k kind }: what BuffettForever bought
                   -- that hasn't been collected yet (Pricing/Collect.lua)
    made = {},     -- [itemID] = { q, t }: what you crafted, still yours to post (Crafting/Craft.lua)
    posted = {},   -- [itemID] = { q, t }: what the bar posted, which counts as made again if it comes back by
                   -- mail, expired or cancelled (Pricing/Post.lua)
    results = {    -- the craftable-items list (UI/ResultsList.lua); view: "tray", "vendor", "flips" or "professions"
        sortKey = "rank", sortDesc = true, knownOnly = false, showUnconfirmed = false, view = "tray",
        -- the Profession profits view's own filters, and its collapsed groups ([skillLine] = true)
        professions = { knownOnly = true, showUnconfirmed = false, collapsed = {} },
    },
}

local migrations = {
    -- 1 -> 2: recipesSeen (recipes a profession window listed) proved nothing: GetAllRecipeIDs lists
    -- the whole skill line, Season-of-Discovery recipes included [F-123].
    [1] = function(db) db.recipesSeen = nil end,
    -- 2 -> 3: deposits follow Forever's formula [F-129]; the measured per-unit figures are dropped and the
    -- table now records commodity or gear per item.
    [2] = function(db)
        db.deposits = {}
        if db.diag then db.diag.deposits = nil end
    end,
}

local function CopyDefaults(src, dst)
    for key, value in pairs(src) do
        if type(value) == "table" then
            if type(dst[key]) ~= "table" then dst[key] = {} end
            CopyDefaults(value, dst[key])
        elseif dst[key] == nil then
            dst[key] = value
        end
    end
end

local events = {}
ns.events = events
local frame = CreateFrame("Frame")
ns.eventFrame = frame

-- Stays registered after our own load: other modules hear about Blizzard's LoadOnDemand
-- addons (the Auction House UI) through ns.On("ADDON_LOADED", fn).
function events:ADDON_LOADED(loaded)
    if loaded ~= addonName then
        ns.Fire("ADDON_LOADED", loaded)
        return
    end
    BuffettForeverDB = BuffettForeverDB or {}
    local db = BuffettForeverDB
    local from = db.dbVersion or DB_VERSION
    if from > DB_VERSION then
        ns.readOnlyDB = true   -- written by a newer version: keep it, don't migrate
    else
        for version = from, DB_VERSION - 1 do
            if migrations[version] then migrations[version](db) end
        end
        db.dbVersion = DB_VERSION
    end
    CopyDefaults(defaults, db)
    ns.db = db
    BuffettForeverCharDB = BuffettForeverCharDB or {}
    CopyDefaults(charDefaults, BuffettForeverCharDB)
    ns.charDB = BuffettForeverCharDB
    if ns.MinimapButton then ns.MinimapButton.Init() end
    if ns.BuildOptions then ns.BuildOptions(db) end
end

-- Fires after ADDON_LOADED when the saved file is too big: the game won't save it this
-- session [F-127]. Stop growing it and tell the player.
function events:SAVED_VARIABLES_TOO_LARGE(loaded)
    if loaded ~= addonName then return end
    ns.readOnlyDB = true
    ns.svTooLarge = true
    ns.Print(L["The saved price data is too large: the game won't save it this session. Scanning is paused."])
    ns.Fire("READ_ONLY")
end

function events:PLAYER_LOGIN()
    local version = C_AddOns.GetAddOnMetadata(addonName, "Version") or "dev"
    ns.Print(L["loaded"] .. " v" .. version)
    ns.Fire("LOGIN")
end

function events:PLAYER_LOGOUT()
    ns.Fire("LOGOUT")
end

-- Combat, for every module that stops in it (Buy, Collect, Craft, Post): ns.inCombat is set by the event,
-- since InCombatLockdown lags it.
function ns.InCombat()
    return ns.inCombat == true or InCombatLockdown()
end

function events:PLAYER_REGEN_DISABLED()
    ns.inCombat = true
    ns.Fire("COMBAT_STARTED")
end

function events:PLAYER_REGEN_ENABLED()
    ns.inCombat = false
    for i = 1, #combatQueue do combatQueue[i]() end
    wipe(combatQueue)
    ns.Fire("COMBAT_ENDED")
end

-- Blizzard blocked one of our calls: the payload names the addon and the function. Kept in diag.blocked;
-- ACTION_BLOCKED(event, fn) tells whichever action was open (a purchase, a take, a craft or a post).
local function Blocked(event, who, fn)
    if who ~= addonName then return end
    if ns.db and not ns.readOnlyDB then ns.db.diag.blocked = { t = GetServerTime(), event = event, fn = tostring(fn) } end
    ns.Fire("ACTION_BLOCKED", event, fn)
end

function events:ADDON_ACTION_BLOCKED(who, fn) Blocked("ADDON_ACTION_BLOCKED", who, fn) end
function events:ADDON_ACTION_FORBIDDEN(who, fn) Blocked("ADDON_ACTION_FORBIDDEN", who, fn) end

-- The Auction House's error doesn't name the action it refused: only one of a purchase or a post is open
-- at a time, and that one takes it.
function events:AUCTION_HOUSE_SHOW_ERROR(err)
    ns.Fire("AH_ERROR", err)
end

-- What you carry changed (the Vendor crafts view counts it).
function events:BAG_UPDATE_DELAYED()
    ns.Fire("BAGS_CHANGED")
end

-- At an auctioneer: scanning and searching are only possible in between.
function events:AUCTION_HOUSE_SHOW()
    ns.ahOpen = true
    ns.Fire("AH_OPEN")
end

function events:AUCTION_HOUSE_CLOSED()
    if not ns.ahOpen then return end
    ns.ahOpen = false
    ns.Fire("AH_CLOSED")
end

frame:SetScript("OnEvent", function(self, event, ...)
    local handler = events[event]
    if handler then handler(self, ...) end
end)
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("SAVED_VARIABLES_TOO_LARGE")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("ADDON_ACTION_BLOCKED")
frame:RegisterEvent("ADDON_ACTION_FORBIDDEN")
frame:RegisterEvent("AUCTION_HOUSE_SHOW_ERROR")
frame:RegisterEvent("AUCTION_HOUSE_SHOW")
frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
frame:RegisterEvent("BAG_UPDATE_DELAYED")
