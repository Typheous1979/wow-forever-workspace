local addonName, ns = ...

-- Blizzard Settings panel (Options > AddOns). Built from ADDON_LOADED via ns.BuildOptions(db),
-- after the SavedVariables table exists, so controls bind to the live table.

function ns.BuildOptions(db)
    local L = ns.L
    local category, layout = Settings.RegisterVerticalLayoutCategory("$TITLE")
$OPTIONS_HEADER
    local enabled = Settings.RegisterAddOnSetting(category, "${NAME}_Enabled", "enabled", db,
        type(true), L["Enable"], true)
    Settings.CreateCheckbox(category, enabled, L["Turn $TITLE on or off."])
$OPTIONS_MINIMAP
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
