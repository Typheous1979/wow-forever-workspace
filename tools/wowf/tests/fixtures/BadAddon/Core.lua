-- no namespace header on purpose
BadAddonDB = BadAddonDB or {}
local json = require("json")
os.exit(1)
local name = GetSpellInfo(8690)
local f = CreateFrame("Frame")
f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
f:RegisterEvent("PLAYER_LOGINN")
InterfaceOptions_AddCategory(f)
PlaySoundFile("Sound\\Interface\\LevelUp.ogg")
PlaySound("igMainMenuOpen")
C_Fakeness.DoThing()
C_Sound.PlaySoundz(1)
local t = C_Timer.After(1, function() end)
if WOW_PROJECT_ID == WOW_PROJECT_CLASSIC then print("classic") end
SLASH_BADADDON1 = "/bad"
SlashCmdList["BADADON"] = function() end
local pct = UnitHealth("player") + 1
ChatFrame_OpenChat("hi")
