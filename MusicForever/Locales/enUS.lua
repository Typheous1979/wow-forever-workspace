local addonName, ns = ...

-- Strings. Keys are the English text, so English needs no entries: a missing key
-- returns the key itself. Other locales add files that fill L[key] = "translation"
-- when GetLocale() matches.
local L = setmetatable({}, { __index = function(_, key) return key end })
ns.L = L
