local addonName, ns = ...

-- Mixer: reads and writes the game's sound CVars, applies presets, and keeps
-- one level of undo. Never unmutes or raises volume on its own; every change
-- here comes from an explicit click, key binding or preset.

local Mixer = {}
ns.Mixer = Mixer

local channelsByKey, optionsByKey = {}, {}
for _, ch in ipairs(ns.Channels) do channelsByKey[ch.key] = ch end
for _, opt in ipairs(ns.SoundOptions) do optionsByKey[opt.key] = opt end

local function GetCVarRaw(name)
    return C_CVar.GetCVar(name)
end

local function SetCVarRaw(name, value)
    if GetCVarRaw(name) == nil then return false end   -- not present on this build
    return C_CVar.SetCVar(name, value)
end

-- A channel or option is shown only if its CVar exists on this client.
function Mixer.IsChannelSupported(key)
    local ch = channelsByKey[key]
    return ch ~= nil and GetCVarRaw(ch.volume) ~= nil
end

function Mixer.IsOptionSupported(key)
    local opt = optionsByKey[key]
    return opt ~= nil and GetCVarRaw(opt.cvar) ~= nil
end

function Mixer.GetVolume(key)
    local ch = channelsByKey[key]
    return ch and tonumber(GetCVarRaw(ch.volume)) or 0
end

function Mixer.SetVolume(key, value)
    local ch = channelsByKey[key]
    if not ch then return end
    value = math.min(1, math.max(0, value))
    SetCVarRaw(ch.volume, string.format("%.2f", value))
    ns.Fire("MIXER_CHANGED")
end

function Mixer.IsEnabled(key)
    local ch = channelsByKey[key]
    return ch ~= nil and GetCVarRaw(ch.enable) == "1"
end

function Mixer.SetEnabled(key, enabled)
    local ch = channelsByKey[key]
    if not ch or GetCVarRaw(ch.enable) == nil then return end
    SetCVarRaw(ch.enable, enabled and "1" or "0")
    ns.Fire("MIXER_CHANGED")
end

function Mixer.GetOption(key)
    local opt = optionsByKey[key]
    return opt ~= nil and GetCVarRaw(opt.cvar) == "1"
end

function Mixer.SetOption(key, enabled)
    local opt = optionsByKey[key]
    if not opt then return end
    SetCVarRaw(opt.cvar, enabled and "1" or "0")
    ns.Fire("MIXER_CHANGED")
end

-- Snapshot of every supported setting, in preset shape.
function Mixer.Snapshot()
    local snap = { volume = {}, enable = {}, options = {} }
    for _, ch in ipairs(ns.Channels) do
        if Mixer.IsChannelSupported(ch.key) then
            snap.volume[ch.key] = Mixer.GetVolume(ch.key)
            snap.enable[ch.key] = Mixer.IsEnabled(ch.key)
        end
    end
    for _, opt in ipairs(ns.SoundOptions) do
        if Mixer.IsOptionSupported(opt.key) then
            snap.options[opt.key] = Mixer.GetOption(opt.key)
        end
    end
    return snap
end

local function ApplyRaw(preset)
    for key, value in pairs(preset.volume or {}) do
        local ch = channelsByKey[key]
        if ch then SetCVarRaw(ch.volume, string.format("%.2f", math.min(1, math.max(0, value)))) end
    end
    for key, value in pairs(preset.enable or {}) do
        local ch = channelsByKey[key]
        if ch then SetCVarRaw(ch.enable, value and "1" or "0") end
    end
    for key, value in pairs(preset.options or {}) do
        local opt = optionsByKey[key]
        if opt then SetCVarRaw(opt.cvar, value and "1" or "0") end
    end
end

local undoSnapshot, undoName

function Mixer.ApplyPreset(preset)
    if not preset then return end
    undoSnapshot, undoName = Mixer.Snapshot(), preset.name
    ApplyRaw(preset)
    if ns.charDB then ns.charDB.lastPreset = preset.name end
    ns.Fire("MIXER_CHANGED")
    ns.Print(string.format(ns.L["Applied preset: %s"], preset.name))
end

function Mixer.CanUndo()
    return undoSnapshot ~= nil, undoName
end

function Mixer.Undo()
    if not undoSnapshot then return end
    ApplyRaw(undoSnapshot)
    ns.Print(string.format(ns.L["Undid preset: %s"], undoName or "?"))
    undoSnapshot, undoName = nil, nil
    ns.Fire("MIXER_CHANGED")
end

-- Built-in presets first, then the player's own (sorted by name).
function Mixer.GetPresets()
    local list = {}
    for _, p in ipairs(ns.BuiltinPresets) do list[#list + 1] = p end
    local user = {}
    for name, p in pairs(ns.db.presets) do
        user[#user + 1] = { name = name, volume = p.volume, enable = p.enable, options = p.options, user = true }
    end
    table.sort(user, function(a, b) return a.name < b.name end)
    for _, p in ipairs(user) do list[#list + 1] = p end
    return list
end

function Mixer.FindPreset(name)
    for _, p in ipairs(Mixer.GetPresets()) do
        if p.name == name then return p end
    end
end

function Mixer.SaveUserPreset(name)
    name = name and strtrim(name) or ""
    if name == "" then return false end
    for _, p in ipairs(ns.BuiltinPresets) do
        if p.name == name then return false end   -- built-in names are reserved
    end
    ns.db.presets[name] = Mixer.Snapshot()
    ns.Fire("PRESETS_CHANGED")
    ns.Print(string.format(ns.L["Saved preset: %s"], name))
    return true
end

function Mixer.DeleteUserPreset(name)
    if ns.db.presets[name] then
        ns.db.presets[name] = nil
        ns.Fire("PRESETS_CHANGED")
    end
end

function Mixer.CyclePreset()
    local list = Mixer.GetPresets()
    if #list == 0 then return end
    local last = ns.charDB and ns.charDB.lastPreset
    local index = 1
    for i, p in ipairs(list) do
        if p.name == last then index = i % #list + 1 end
    end
    Mixer.ApplyPreset(list[index])
end

-- Key binding helpers.
function Mixer.Nudge(key, delta)
    if not Mixer.IsChannelSupported(key) then return end
    local value = math.min(1, math.max(0, Mixer.GetVolume(key) + delta))
    Mixer.SetVolume(key, value)
    ns.Print(string.format("%s %d%%", ns.L[channelsByKey[key].label], math.floor(value * 100 + 0.5)))
end

function Mixer.ToggleEnabled(key)
    if not Mixer.IsChannelSupported(key) then return end
    local enabled = not Mixer.IsEnabled(key)
    Mixer.SetEnabled(key, enabled)
    ns.Print(string.format("%s: %s", ns.L[channelsByKey[key].label], enabled and ns.L["on"] or ns.L["off"]))
end

-- True when PlayMusic would be silent.
function Mixer.IsMusicAudible()
    return Mixer.IsEnabled("master") and Mixer.IsEnabled("music")
        and Mixer.GetVolume("master") > 0 and Mixer.GetVolume("music") > 0
end

-- Settings changed elsewhere (Blizzard's Audio page, other addons): refresh views.
local watched = {}
for _, ch in ipairs(ns.Channels) do watched[ch.volume] = true; watched[ch.enable] = true end
for _, opt in ipairs(ns.SoundOptions) do watched[opt.cvar] = true end

function ns.events:CVAR_UPDATE(name)
    if watched[name] then ns.Fire("MIXER_CHANGED") end
end
ns.eventFrame:RegisterEvent("CVAR_UPDATE")
