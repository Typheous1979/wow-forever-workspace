local addonName, ns = ...

-- Slash commands. Plain /bf opens or closes the main window.

local function Help()
    local L = ns.L
    ns.Print("/bf  " .. L["open or close the window"])
    ns.Print("/bf scan  " .. L["full Auction House scan (at an auctioneer)"])
    ns.Print("/bf options  " .. L["open the settings"])
    ns.Print("/bf diag  " .. L["scanner diagnostics"])
    ns.Print("/bf selftest  " .. L["check the price math against its test vectors"])
    ns.Print("/bf help | minimap")
end

local function SelfTest()
    local passed, failed = ns.Econ.SelfTest(function(name, ok, detail)
        ns.Print((ok and "|cff33ff33PASS|r " or "|cffff3333FAIL|r ") .. name .. ": " .. detail)
    end)
    ns.Print(string.format(ns.L["selftest: %d passed, %d failed"], passed, failed))
end

SLASH_BUFFETTFOREVER1 = "/bf"
SLASH_BUFFETTFOREVER2 = "/buffett"
SlashCmdList["BUFFETTFOREVER"] = function(msg)
    local cmd = string.lower(string.match(msg or "", "^%s*(%S*)") or "")
    if cmd == "" or cmd == "toggle" then
        ns.Main.Toggle()
    elseif cmd == "help" then
        Help()
    elseif cmd == "scan" then
        ns.Scanner.Start()
    elseif cmd == "diag" then
        ns.Scanner.PrintDiag()
    elseif cmd == "selftest" then
        SelfTest()
    elseif cmd == "options" then
        if ns.OpenOptions then ns.OpenOptions() end
    elseif cmd == "minimap" then
        ns.MinimapButton.Toggle()
    else
        ns.Print(ns.L["Unknown command:"] .. " " .. cmd)
        Help()
    end
end
