local addonName, ns = ...

-- Default (English) strings. Missing keys fall back to the key itself.
local L = setmetatable({}, { __index = function(_, key) return key end })
ns.L = L

L["loaded"] = "loaded"
L["enabled"] = "enabled"
L["disabled"] = "disabled"
L["Enable"] = "Enable"
L["Unknown command:"] = "Unknown command:"
