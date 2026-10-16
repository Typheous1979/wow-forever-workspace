local addonName, ns = ...

-- Slash commands. Plain /$SLASH opens or closes the main window.

local function Help()
    local L = ns.L
    ns.Print("/$SLASH  " .. L["open or close the window"])
    ns.Print("/$SLASH options  " .. L["open the settings"])
    ns.Print("/$SLASH help$SLASH_MINIMAP_HELP")
end

$SLASH_LINES
SlashCmdList["$UPPER"] = function(msg)
    local cmd = string.lower(string.match(msg or "", "^%s*(%S*)") or "")
    if cmd == "" or cmd == "toggle" then
        ns.Main.Toggle()
    elseif cmd == "help" then
        Help()
    elseif cmd == "options" then
        if ns.OpenOptions then ns.OpenOptions() end
$SLASH_MINIMAP    else
        ns.Print(ns.L["Unknown command:"] .. " " .. cmd)
        Help()
    end
end
