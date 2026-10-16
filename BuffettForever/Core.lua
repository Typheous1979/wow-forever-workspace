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
local DB_VERSION = 1
local defaults = {
    minimap = { angle = 200, shown = true },   -- minimap button: degrees around the edge, visible
    settings = {
        historyDays = 14,                       -- days of price history kept per item (pruned at login)
    },
    markets = {},   -- [marketKey] = { items = { [itemID] = price row }, scan = last full scan } (Pricing/PriceDB.lua)
    vendor = {},    -- [itemID] = { p = unit buy price, t, lim } (Pricing/Merchant.lua)
    diag = {},      -- scanner diagnostics for the open AH probes (Pricing/Scanner.lua)
}
local charDefaults = {
    window = {},   -- main window position (per character)
}

local migrations = {
    -- [1] = function(db) ... end,   -- upgrades data written by version 1 to version 2
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

function events:PLAYER_REGEN_ENABLED()
    for i = 1, #combatQueue do combatQueue[i]() end
    wipe(combatQueue)
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
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("AUCTION_HOUSE_SHOW")
frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
