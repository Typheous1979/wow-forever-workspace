local addonName, ns = ...

-- WowfProbe: records what this client really provides into WowfProbeDB.
-- Safety rules: only whitelisted calls (pcall-wrapped); everything else is
-- inspected with type() only. Never tostring/../# on unknown values. Never
-- stores secrets (SavedVariables cannot hold them).

local PREFIX = "|cff66ccff[WowfProbe]|r "
local MAX_RUNS = 2
local events = {}
local frame = CreateFrame("Frame")
local pendingMode

local function Say(msg)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg)
end

local function IsSecret(v)
    return type(issecretvalue) == "function" and issecretvalue(v) and true or false
end

-- Plain(v): a value safe to store/print, or a marker.
local function Plain(v)
    if v == nil then return nil end
    if IsSecret(v) then return "<secret>" end
    local t = type(v)
    if t == "string" or t == "number" or t == "boolean" then return v end
    return "<" .. t .. ">"
end

-- Call(fn, ...): whitelisted, pcall-wrapped call; returns up to 6 plain values.
local function Call(fn, ...)
    if type(fn) ~= "function" then return "<missing>" end
    local ok, a, b, c, d, e, f = pcall(fn, ...)
    if not ok then return "<error>" end
    return Plain(a), Plain(b), Plain(c), Plain(d), Plain(e), Plain(f)
end

-- Resolve "C_X.Fn" through tables with rawget/type only (no calls, no metamethods).
local function Resolve(path)
    local cur = _G
    for part in string.gmatch(path, "[^%.]+") do
        if type(cur) ~= "table" then return "nil" end
        local ok, nxt = pcall(rawget, cur, part)
        if not ok then return "forbidden" end
        cur = nxt
    end
    return type(cur)
end

local function SortedJoin(list)
    table.sort(list)
    return table.concat(list, "\n")
end

local function TableKeys(t)
    local keys = {}
    local ok = pcall(function()
        for k in pairs(t) do
            if type(k) == "string" then keys[#keys + 1] = k end
        end
    end)
    return ok and keys or nil
end

local function SoundCVars()
    local out = {}
    local names = {
        "Sound_EnableAllSound", "Sound_MasterVolume", "Sound_EnableMusic", "Sound_MusicVolume",
        "Sound_EnableSFX", "Sound_SFXVolume", "Sound_EnableAmbience", "Sound_AmbienceVolume",
        "Sound_EnableDialog", "Sound_DialogVolume", "Sound_ZoneMusicNoDelay",
        "Sound_EnableSoundWhenGameIsInBG", "Sound_MaxCacheableSizeInBytes",
        "addonCombatRestrictionsForced", "addonEncounterRestrictionsForced",
        "addonMapRestrictionsForced", "addonChatRestrictionsForced", "scriptErrors", "taintLog",
    }
    local get = C_CVar and C_CVar.GetCVar
    for _, n in ipairs(names) do
        out[n] = Call(get, n)
    end
    return out
end

local function Meta()
    local m = {}
    m.version, m.build, m.buildDate, m.interface = Call(GetBuildInfo)
    m.WOW_PROJECT_ID = Plain(WOW_PROJECT_ID)
    m.WOW_PROJECT_CAMELOT = Plain(WOW_PROJECT_CAMELOT)
    m.WOW_PROJECT_MAINLINE = Plain(WOW_PROJECT_MAINLINE)
    m.WOW_PROJECT_CLASSIC = Plain(WOW_PROJECT_CLASSIC)
    m.tocGame = Call(C_AddOns and C_AddOns.GetAddOnMetadata, addonName, "X-Game")
    m.tocFamily = Call(C_AddOns and C_AddOns.GetAddOnMetadata, addonName, "X-Family")
    m.locale = Call(GetLocale)
    m.region = Call(GetCurrentRegion)
    m.regionName = Call(GetCurrentRegionName)
    m.inCombat = Call(InCombatLockdown)
    m.inInstance, m.instanceType = Call(IsInInstance)
    if C_GameRules then
        m.foreverPreset = Call(C_GameRules.GetForeverExperiencePreset)
        m.hardcore = Call(C_GameRules.IsHardcoreActive)
        m.selfFoundAllowed = Call(C_GameRules.IsSelfFoundAllowed)
        m.activeGameMode = Call(C_GameRules.GetActiveGameMode)
    end
    m.secretRestrictions = Call(C_Secrets and C_Secrets.HasSecretRestrictions)
    -- secret checks: store only booleans
    -- not "ok and IsSecret(v) or x": that turns a real false into x
    local function SecretOf(fn, ...)
        local ok, v = pcall(fn, ...)
        if not ok then return "<error>" end
        return IsSecret(v)
    end
    m.healthSecret = SecretOf(UnitHealth, "player")
    m.healthMaxSecret = SecretOf(UnitHealthMax, "player")
    m.nameSecret = SecretOf(UnitName, "player")
    m.loadstring_untainted = type(loadstring_untainted)
    m.cvars = SoundCVars()
    -- presence of interesting globals (type only)
    local watch = {
        "PlayMusic", "StopMusic", "PlaySoundFile", "StopSound", "MuteSoundFile", "UnmuteSoundFile",
        "PlaySound", "import", "require", "issecretvalue", "canaccessvalue", "scrubsecretvalues",
        "GetSpellInfo", "GetItemInfo", "UnitAura", "GetAddOnMetadata", "SetDesaturation",
        "CombatLogGetCurrentEventInfo", "InterfaceOptions_AddCategory", "UIReload",
        "loadstring", "getfenv", "setfenv", "newproxy", "debugstack",
    }
    m.globals = {}
    for _, name in ipairs(watch) do
        m.globals[name] = type(rawget(_G, name))
    end
    m.time = time()
    return m
end

local function QuickSurface()
    local s = { namespaces = {}, libs = {} }
    local nsCount = 0
    for k, v in pairs(_G) do
        if type(k) == "string" and string.sub(k, 1, 2) == "C_" and type(v) == "table" and not IsSecret(v) then
            local keys = TableKeys(v)
            s.namespaces[k] = keys and SortedJoin(keys) or "<forbidden>"
            nsCount = nsCount + 1
        end
    end
    for _, lib in ipairs({ "string", "table", "math", "bit", "os", "coroutine", "debug",
                           "Settings", "Menu", "MenuUtil", "EventRegistry", "SOUNDKIT", "Constants" }) do
        local t = rawget(_G, lib)
        if type(t) == "table" then
            local keys = TableKeys(t)
            s.libs[lib] = keys and SortedJoin(keys) or "<forbidden>"
        end
    end
    s.namespaceCount = nsCount
    return s
end

local function FullSurface()
    local byType = {}
    for k, v in pairs(_G) do
        if type(k) == "string" then
            local t = IsSecret(v) and "secret" or type(v)
            local list = byType[t]
            if not list then
                list = {}
                byType[t] = list
            end
            list[#list + 1] = k
        end
    end
    local out = { counts = {} }
    for t, list in pairs(byType) do
        out.counts[t] = #list
        out[t] = SortedJoin(list)
    end
    local enum = {}
    if type(Enum) == "table" then
        local keys = TableKeys(Enum)
        if keys then
            for _, k in ipairs(keys) do
                local sub = rawget(Enum, k)
                if type(sub) == "table" then
                    local fk = TableKeys(sub)
                    enum[k] = fk and SortedJoin(fk) or "<forbidden>"
                end
            end
        end
    end
    out.enum = enum
    return out
end

local function RunQueries()
    local q = ns.queries or {}
    local out = { functions = {}, events = {}, addons = {} }
    for _, path in ipairs(q.functions or {}) do
        out.functions[path] = Resolve(path)
    end
    local isValid = C_EventUtils and C_EventUtils.IsEventValid
    for _, ev in ipairs(q.events or {}) do
        out.events[ev] = Call(isValid, ev)
    end
    local A = C_AddOns or {}
    for _, name in ipairs(q.addons or {}) do
        local exists = Call(A.DoesAddOnExist, name)
        local r = { exists = exists }
        if exists == true then
            local _, title, _, loadable, reason, security = Call(A.GetAddOnInfo, name)
            r.title, r.loadable, r.reason, r.security = title, loadable, reason, security
            r.interface = Call(A.GetAddOnInterfaceVersion, name)
            r.enabledState = Call(A.GetAddOnEnableState, name)
        end
        out.addons[name] = r
    end
    return out
end

local function Store(run)
    WowfProbeDB = WowfProbeDB or {}
    local db = WowfProbeDB
    db.schema = 1
    db.runs = db.runs or {}
    -- replace a run for the same build, else push; keep MAX_RUNS
    for i = #db.runs, 1, -1 do
        if db.runs[i].meta and db.runs[i].meta.build == run.meta.build then
            table.remove(db.runs, i)
        end
    end
    table.insert(db.runs, run)
    while #db.runs > MAX_RUNS do
        table.remove(db.runs, 1)
    end
end

local function Run(mode, announce)
    if InCombatLockdown() then
        pendingMode = mode
        Say("in combat — will run when combat ends.")
        return
    end
    local run = { mode = mode, meta = Meta() }
    run.quick = QuickSurface()
    if mode == "full" then
        run.full = FullSurface()
    end
    run.queries = RunQueries()
    Store(run)
    if announce then
        local m = run.meta
        Say(("build %s  interface %s  WOW_PROJECT_ID %s  game %s/%s  C_ namespaces %d"):format(
            tostring(m.build), tostring(m.interface), tostring(m.WOW_PROJECT_ID),
            tostring(m.tocFamily), tostring(m.tocGame), run.quick.namespaceCount))
        Say(("secret? health %s  healthMax %s  name %s   PlayMusic: %s  PlaySoundFile: %s"):format(
            tostring(m.healthSecret), tostring(m.healthMaxSecret), tostring(m.nameSecret),
            m.globals.PlayMusic, m.globals.PlaySoundFile))
        local ok, dialog = pcall(StaticPopup_Show, "WOWFPROBE_RELOAD")
        -- recorded so the report can tell "not shown" from "errored"; written at that reload
        run.popup = { ok = ok, shown = (ok and dialog ~= nil) or false,
                              err = (not ok) and tostring(dialog) or nil }
        if ok and dialog then
            Say("saved. Click Reload UI (or type /reload) so the results are written to disk.")
        else
            Say("saved. Type /reload now so the results are written to disk.")
        end
    end
end

StaticPopupDialogs["WOWFPROBE_RELOAD"] = {
    text = "WowfProbe finished. Reload the UI now so the results are written to disk?",
    button1 = "Reload UI",
    button2 = "Cancel",
    OnAccept = function() ReloadUI() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

function events:PLAYER_LOGIN()
    C_Timer.After(5, function() Run("quick", false) end)
end

function events:PLAYER_REGEN_ENABLED()
    if pendingMode then
        local mode = pendingMode
        pendingMode = nil
        Run(mode, true)
    end
end

frame:SetScript("OnEvent", function(self, event, ...)
    local handler = events[event]
    if handler then handler(self, ...) end
end)
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")

SLASH_WOWFPROBE1 = "/wowfprobe"
SlashCmdList["WOWFPROBE"] = function(msg)
    local mode = string.lower(string.match(msg or "", "^%s*(%S*)") or "")
    if mode == "" then mode = "quick" end
    if mode ~= "quick" and mode ~= "full" and mode ~= "queries" then
        Say("usage: /wowfprobe [quick|full|queries]")
        return
    end
    Run(mode == "queries" and "quick" or mode, true)
end
