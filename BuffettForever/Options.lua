local addonName, ns = ...

-- Blizzard Settings panel (Options > AddOns > BuffettForever). Built from ADDON_LOADED via
-- ns.BuildOptions(db), after the SavedVariables table exists, so controls bind to the live
-- table. The economics settings (AH cut, margin of safety, owned-materials policy, history
-- days) arrive with milestone M5; see CLAUDE.md.

function ns.BuildOptions(db)
    local L = ns.L
    local category, layout = Settings.RegisterVerticalLayoutCategory("BuffettForever")
    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(
        "BuffettForever |cff9d9d9d" .. L["by Typheous"] .. "|r"))

    local minimap = Settings.RegisterAddOnSetting(category, "BuffettForever_MinimapShown", "shown", db.minimap,
        type(true), L["Show minimap button"], true)
    Settings.CreateCheckbox(category, minimap, L["The BuffettForever button on the minimap."])
    minimap:SetValueChangedCallback(function(_, value) ns.MinimapButton.SetShown(value) end)

    Settings.RegisterAddOnCategory(category)
    ns.settingsCategory = category
    ns.settingsLayout = layout
end

function ns.OpenOptions()
    if not ns.settingsCategory then return end
    ns.RunOutOfCombat(function()
        Settings.OpenToCategory(ns.settingsCategory:GetID())
    end)
end
