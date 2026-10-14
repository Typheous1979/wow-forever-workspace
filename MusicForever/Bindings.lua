local addonName, ns = ...

-- Key bindings (Game Menu > Options > Keybindings > MusicForever). Bindings.xml
-- calls MusicForever_Binding(action). Nothing here is protected, so the keys
-- also work in combat.

local L = ns.L
local STEP = 0.05

_G.BINDING_NAME_MUSICFOREVER_TOGGLE = L["Open or close MusicForever"]
_G.BINDING_NAME_MUSICFOREVER_PLAYSTOP = L["Play / stop"]
_G.BINDING_NAME_MUSICFOREVER_NEXT = L["Next track"]
_G.BINDING_NAME_MUSICFOREVER_PREV = L["Previous track"]
_G.BINDING_NAME_MUSICFOREVER_REVERT = L["Return to game music"]
_G.BINDING_NAME_MUSICFOREVER_MUSIC_UP = L["Music volume up"]
_G.BINDING_NAME_MUSICFOREVER_MUSIC_DOWN = L["Music volume down"]
_G.BINDING_NAME_MUSICFOREVER_MASTER_UP = L["Master volume up"]
_G.BINDING_NAME_MUSICFOREVER_MASTER_DOWN = L["Master volume down"]
_G.BINDING_NAME_MUSICFOREVER_MUTE_MUSIC = L["Game music on / off"]
_G.BINDING_NAME_MUSICFOREVER_CYCLE_PRESET = L["Next mixer preset"]
_G.BINDING_NAME_MUSICFOREVER_MINI = L["Show / hide mini player"]

local actions = {
    toggle = function() ns.Main.Toggle() end,
    playstop = function() ns.Player.TogglePlay() end,
    next = function() ns.Player.Next() end,
    prev = function() ns.Player.Previous() end,
    revert = function() ns.Player.ReturnToGame() end,
    musicUp = function() ns.Mixer.Nudge("music", STEP) end,
    musicDown = function() ns.Mixer.Nudge("music", -STEP) end,
    masterUp = function() ns.Mixer.Nudge("master", STEP) end,
    masterDown = function() ns.Mixer.Nudge("master", -STEP) end,
    muteMusic = function() ns.Mixer.ToggleEnabled("music") end,
    cyclePreset = function() ns.Mixer.CyclePreset() end,
    mini = function() ns.MiniPlayer.Toggle() end,
}

function MusicForever_Binding(action)
    local fn = actions[action]
    if fn then fn() end
end
