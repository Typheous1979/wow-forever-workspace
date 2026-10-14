local addonName, ns = ...

-- $TITLE — core: namespace helpers, SavedVariables lifecycle, event dispatch.
-- Target: WoW Forever (game type Camelot, interface 16001).

local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })
ns.L = L

local PREFIX = "|cff66ccff[$TITLE]|r "

function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg)
end

-- Secret-value helpers: never do math, comparisons or print on secrets.
function ns.IsSecret(value)
    return type(issecretvalue) == "function" and issecretvalue(value) == true
end

function ns.SafeText(value, fallback)
    if value == nil or ns.IsSecret(value) then return fallback end
    return tostring(value)
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
    enabled = true,
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

function events:ADDON_LOADED(loaded)
    if loaded ~= addonName then return end
    $SVNAME = $SVNAME or {}
    local db = $SVNAME
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
$CHARDB_INIT    if ns.BuildOptions then ns.BuildOptions(db) end
    self:UnregisterEvent("ADDON_LOADED")
end

function events:PLAYER_LOGIN()
    local version = C_AddOns.GetAddOnMetadata(addonName, "Version") or "dev"
    ns.Print(L["loaded"] .. " v" .. version)
end

function events:PLAYER_REGEN_ENABLED()
    for i = 1, #combatQueue do combatQueue[i]() end
    wipe(combatQueue)
end

frame:SetScript("OnEvent", function(self, event, ...)
    local handler = events[event]
    if handler then handler(self, ...) end
end)
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
