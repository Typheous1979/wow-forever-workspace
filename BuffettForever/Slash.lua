local addonName, ns = ...

-- Slash commands. Plain /bf opens or closes the main window.

local function Help()
    local L = ns.L
    ns.Print("/bf  " .. L["open or close the window"])
    ns.Print("/bf options  " .. L["open the settings"])
    ns.Print("/bf help | minimap")
end

SLASH_BUFFETTFOREVER1 = "/bf"
SLASH_BUFFETTFOREVER2 = "/buffett"
SlashCmdList["BUFFETTFOREVER"] = function(msg)
    local cmd = string.lower(string.match(msg or "", "^%s*(%S*)") or "")
    if cmd == "" or cmd == "toggle" then
        ns.Main.Toggle()
    elseif cmd == "help" then
        Help()
    elseif cmd == "options" then
        if ns.OpenOptions then ns.OpenOptions() end
    elseif cmd == "minimap" then
        ns.MinimapButton.Toggle()
    else
        ns.Print(ns.L["Unknown command:"] .. " " .. cmd)
        Help()
    end
end
