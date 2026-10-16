local addonName, ns = ...

-- Default (English) strings. Keys are the English text: a missing key returns the key
-- itself, so English only needs entries that differ. Other locales add a file that fills
-- L[key] = "translation" when GetLocale() matches.
local L = setmetatable({}, { __index = function(_, key) return key end })
ns.L = L

L["loaded"] = "loaded"
L["enabled"] = "enabled"
L["disabled"] = "disabled"
L["Enable"] = "Enable"
L["Unknown command:"] = "Unknown command:"
