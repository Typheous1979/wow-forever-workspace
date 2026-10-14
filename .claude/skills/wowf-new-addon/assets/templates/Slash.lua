local addonName, ns = ...

SLASH_${UPPER}1 = "/$SLASH"
SlashCmdList["$UPPER"] = function(msg)
    local L = ns.L
    local cmd = string.lower(string.match(msg or "", "^%s*(%S*)") or "")
    if cmd == "" or cmd == "help" then
        ns.Print("/$SLASH help | options | toggle")
    elseif cmd == "options" then
        if ns.OpenOptions then ns.OpenOptions() end
    elseif cmd == "toggle" then
        if ns.db then
            ns.db.enabled = not ns.db.enabled
            ns.Print(ns.db.enabled and L["enabled"] or L["disabled"])
        end
    else
        ns.Print(L["Unknown command:"] .. " " .. cmd)
    end
end
