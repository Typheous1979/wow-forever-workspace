local addonName, ns = ...

-- MusicForever — core: namespace helpers, SavedVariables lifecycle, event dispatch.
-- Target: WoW Forever (game type Camelot, interface 16001).

ns.L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

local PREFIX = "|cff66ccff[MusicForever]|r "

function ns.Print(msg)
    if ns.db and ns.db.settings and ns.db.settings.chatMessages == false then return end
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg)
end

-- Tiny internal message bus so the views refresh when the model changes.
-- Messages: MIXER_CHANGED, PRESETS_CHANGED, PLAYER_STATE, LIBRARY_CHANGED, MUSIC_MUTED
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
    favorites = {},      -- [fileID] = true
    playlists = {},      -- { { name = "...", tracks = { fileID, ... } }, ... }
    presets = {},        -- [name] = { volume = {}, enable = {}, options = {} }
    settings = {
        chatMessages = true,
        fadeOut = true,          -- fade the music out on Return to game music
        repeatMode = "all",      -- "all", "one" or "off"
        shuffle = false,
        revertOnInstance = false,
        revertOnZone = false,
        revertOnCombat = false,
        miniPlayer = false,
    },
}
ns.SettingDefaults = defaults.settings

local charDefaults = {
    window = {},         -- point, relativePoint, x, y
    mini = {},
    lastTab = 1,
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
    MusicForeverDB = MusicForeverDB or {}
    local db = MusicForeverDB
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
    MusicForeverCharDB = MusicForeverCharDB or {}
    CopyDefaults(charDefaults, MusicForeverCharDB)
    ns.charDB = MusicForeverCharDB
    if ns.Library then ns.Library.Init() end
    if ns.BuildOptions then ns.BuildOptions(db) end
    self:UnregisterEvent("ADDON_LOADED")
end

function events:PLAYER_LOGIN()
    ns.Fire("LOGIN")
    if ns.Player then ns.Player.OnLogin() end
    if ns.MiniPlayer and ns.db.settings.miniPlayer then ns.MiniPlayer.Show() end
end

function events:PLAYER_LOGOUT()
    ns.Fire("LOGOUT")
    if ns.Player then ns.Player.OnLogout() end
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
frame:RegisterEvent("PLAYER_LOGOUT")
