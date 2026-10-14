local addonName, ns = ...

-- "goto" in a comment, and in a string: "goto skip // & | ~"
local events = {}
local frame = CreateFrame("Frame")
local bar = CreateFrame("StatusBar", nil, UIParent)

function events:ADDON_LOADED(loaded)
    if loaded ~= addonName then return end
    GoodAddonDB = GoodAddonDB or {}
    ns.db = GoodAddonDB
    ns.db.lastSeen = os.time()
end

function events:UNIT_HEALTH(unit)
    bar:SetMinMaxValues(0, UnitHealthMax("player"))
    bar:SetValue(UnitHealth("player"))
end

local function Ding()
    PlaySoundFile("Interface\\AddOns\\GoodAddon\\ding.ogg", "Master")
    PlaySound(SOUNDKIT.IG_MAINMENU_OPEN)
end

local ticker = C_Timer.NewTicker(5, Ding)
local isForever = WOW_PROJECT_CAMELOT ~= nil and WOW_PROJECT_ID == WOW_PROJECT_CAMELOT

function GoodAddon_OnAddonCompartmentClick(_, buttonName)
    if ticker and isForever then ticker:Cancel() end
end

SLASH_GOODADDON1 = "/good"
SLASH_GOODADDON2 = "/gd"
SlashCmdList["GOODADDON"] = function(msg) Ding() end

frame:SetScript("OnEvent", function(self, event, ...)
    local handler = events[event]
    if handler then handler(self, ...) end
end)
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterUnitEvent("UNIT_HEALTH", "player")
