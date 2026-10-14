local addonName, ns = ...

-- Blizzard Settings panel (Options > AddOns > MusicForever). Built from ADDON_LOADED
-- via ns.BuildOptions(db), after the SavedVariables table exists, so controls bind
-- to the live table. The mixer itself lives in the main window (/mf).

function ns.BuildOptions(db)
    local L = ns.L
    local s = db.settings
    local category, layout = Settings.RegisterVerticalLayoutCategory("MusicForever")
    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(
        "MusicForever |cff9d9d9d" .. L["by Typheous"] .. "|r"))

    local defaults = ns.SettingDefaults
    local function Checkbox(key, label, tooltip, onChange)
        local setting = Settings.RegisterAddOnSetting(category, "MusicForever_" .. key, key, s,
            type(true), label, defaults[key])
        Settings.CreateCheckbox(category, setting, tooltip)
        if onChange then
            setting:SetValueChangedCallback(function(_, value) onChange(value) end)
        end
    end

    Checkbox("minimapButton", L["Show minimap button"],
        L["The MusicForever button on the minimap. Minimap button collectors such as MinimapButtonButton pick it up."],
        function(value) ns.MinimapButton.SetShown(value) end)
    Checkbox("miniPlayer", L["Show mini player"],
        L["A small movable now-playing bar with play, next and Return to game music."],
        function(value) ns.MiniPlayer.SetEnabled(value) end)
    Checkbox("fadeOut", L["Fade out"],
        L["Fade the music out over about a second when returning to the game's music."])
    Checkbox("chatMessages", L["Chat messages"],
        L["Print short confirmations (preset applied, playlist created, and so on) in chat."])
    Checkbox("revertOnInstance", L["Return to game music in dungeons and raids"],
        L["Stop MusicForever's music when you enter an instance, so you hear its own music."])
    Checkbox("revertOnZone", L["Return to game music on zone change"],
        L["Stop MusicForever's music when you move to a new zone."])
    Checkbox("revertOnCombat", L["Return to game music in combat"],
        L["Stop MusicForever's music when combat starts."])

    Settings.RegisterAddOnCategory(category)
    ns.settingsCategory = category
end

function ns.OpenOptions()
    if not ns.settingsCategory then return end
    ns.RunOutOfCombat(function()
        Settings.OpenToCategory(ns.settingsCategory:GetID())
    end)
end
