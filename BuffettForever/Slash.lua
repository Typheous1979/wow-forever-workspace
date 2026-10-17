local addonName, ns = ...

-- Slash commands. Plain /bf opens or closes the main window.

local function Help()
    local L = ns.L
    ns.Print("/bf  " .. L["open or close the window"])
    ns.Print("/bf scan  " .. L["full Auction House scan (at an auctioneer)"])
    ns.Print("/bf options  " .. L["open the settings"])
    ns.Print("/bf recipes <" .. L["item link or ID"] .. ">  " .. L["the recipes that use or make an item"])
    ns.Print("/bf eval  " .. L["the best recipes for the reagents in your tray"])
    ns.Print("/bf ledger  " .. L["your auction results: the house cut, what sold and what expired"])
    ns.Print("/bf diag  " .. L["diagnostics: scanner, searches, merchant, recipes, mail, deposits, your auctions"])
    ns.Print("/bf selftest  " .. L["check the price math, the recipe data and the sales ledger"])
    ns.Print("/bf help | minimap")
end

-- Runs every suite and saves the outcome in diag.selftest, so it can be read from SavedVariables.
local function SelfTest()
    local failures = {}
    local function report(name, ok, detail)
        ns.Print((ok and "|cff33ff33PASS|r " or "|cffff3333FAIL|r ") .. name .. ": " .. detail)
        if not ok then failures[#failures + 1] = name .. ": " .. detail end
    end
    local passed, failed = 0, 0
    for _, suite in ipairs({ ns.Econ.SelfTest, ns.Evaluator.SelfTest, ns.RecipeIndex.SelfTest, ns.Ledger.SelfTest,
                             ns.Mail.SelfTest, ns.Deposits.SelfTest, ns.Options.SelfTest }) do
        local p, f = suite(report)
        passed, failed = passed + p, failed + f
    end
    ns.Print(string.format(ns.L["selftest: %d passed, %d failed"], passed, failed))
    if ns.db and not ns.readOnlyDB then
        ns.db.diag.selftest = { t = GetServerTime(), build = select(2, GetBuildInfo()), version =
            C_AddOns.GetAddOnMetadata(addonName, "Version"), passed = passed, failed = failed, failures = failures }
    end
end

-- "/bf recipes [Linen Cloth]" (a shift-clicked link) or "/bf recipes 2589"; "all" at the end lists
-- every recipe instead of the first 20.
local function Recipes(msg)
    local lower = string.lower(msg or "")
    local showAll = string.match(lower, "%sall%s*$") ~= nil
    local itemID = tonumber(string.match(lower, "item:(%d+)") or string.match(lower, "^%s*recipes%s+(%d+)") or "")
    if not itemID then
        ns.Print(ns.L["Usage: /bf recipes <item link or ID> [all]"])
        return
    end
    ns.RecipeIndex.PrintFor(itemID, showAll)
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
        ns.Search.PrintDiag()
        ns.Merchant.PrintDiag()
        ns.Harvest.PrintDiag()
        ns.Mail.PrintDiag()
        ns.Deposits.PrintDiag()
        ns.Owned.PrintDiag()
    elseif cmd == "ledger" then
        ns.Ledger.PrintSummary()
    elseif cmd == "selftest" then
        SelfTest()
    elseif cmd == "recipes" then
        Recipes(msg)
    elseif cmd == "eval" then
        ns.Evaluator.PrintTray()
    elseif cmd == "options" then
        if ns.OpenOptions then ns.OpenOptions() end
    elseif cmd == "minimap" then
        ns.MinimapButton.Toggle()
    else
        ns.Print(ns.L["Unknown command:"] .. " " .. cmd)
        Help()
    end
end
