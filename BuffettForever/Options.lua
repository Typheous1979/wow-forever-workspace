local addonName, ns = ...

-- Blizzard Settings panel (Options > AddOns > BuffettForever; /bf options, or right-click the minimap
-- button). Built from ADDON_LOADED via ns.BuildOptions(db), after the SavedVariables table exists, so
-- the controls bind to the live table: db.settings, which every evaluation reads (Economics/Evaluator.lua
-- LiveContext). A change fires SETTINGS_CHANGED and the list re-ranks (UI/ResultsList.lua). The
-- defaults are Core.lua's (ns.DEFAULT_SETTINGS), so the panel's Defaults button and a new install
-- agree; Options.SelfTest checks that each default is a choice the panel offers.

local L = ns.L
local Options = {}
ns.Options = Options

Options.SLIDERS = {   -- [key] = { min, max, step }
    margin = { 0, 1, 0.05 },
    cut = { 0, 0.15, 0.005 },
    saleChance = { 0.05, 1, 0.05 },
    historyDays = { 7, 30, 1 },
}
Options.MIN_PROFITS = { 0, 100, 500, 1000, 2500, 5000, 10000, 20000, 50000, 100000 }   -- copper per craft
Options.GRADES = { "A", "B", "C", "D" }
Options.POLICIES = { "opportunity", "free", "replacement" }

local GRADE_TEXT = {   -- label, tooltip
    A = { "A: the best data only", "A recent scan, 5 or more days seen, a steady price, twice the depth you need." },
    B = { "B" }, C = { "C" },
    D = { "D: any data", "Even one scan or a thin market can back a recommendation." },
}
local POLICY_TEXT = {
    opportunity = { "What they'd sell for", "What you give up by using them: their price on the AH or at a vendor." },
    free = { "Nothing", "Only the gold you spend counts, so the profit includes what your materials are worth." },
    replacement = { "What replacing them costs", "What buying them again would cost, on the AH or from a vendor." },
}
local PRICE_TEXT = {   -- Sell on AH's price rules (Pricing/Post.lua)
    match = { "The cheapest listing", "The same price as the cheapest listing by others, as Blizzard's Sell tab does." },
    ["1c"] = { "1c under the cheapest", "One copper under the cheapest listing by others, so yours sells first at that price." },
    ["1pct"] = { "1% under the cheapest", "1% under the cheapest listing by others, at least 1c." },
    ["5pct"] = { "5% under the cheapest", "5% under the cheapest listing by others." },
    ["10pct"] = { "10% under the cheapest", "10% under the cheapest listing by others." },
}

local function Pct(v)
    return string.format("%d%%", math.floor(v * 100 + 0.5))
end

-- The house cut slider's tooltip: what the cut is now, and why.
local function CutTooltip()
    local rate, measured, sales, fixed = ns.Ledger.Cut()
    local now
    if fixed then
        now = string.format(L["In use: %s, this figure (measuring is off)."], ns.Ledger.CutText(rate))
    elseif measured then
        now = string.format(L["In use: %s, measured from %d of your sales."], ns.Ledger.CutText(rate, true), sales)
    else
        now = string.format(L["In use: this figure, until %d of your sales worth 1g in all measure it (%d so far)."],
            ns.Econ.CUT_MIN_SALES, sales)
    end
    return L["The Auction House's cut of each sale."] .. "\n\n" .. now
end

function ns.BuildOptions(db)
    local s, defaults = db.settings, ns.DEFAULT_SETTINGS
    local VarType = Settings.VarType or { Boolean = "boolean", Number = "number", String = "string" }
    local category, layout = Settings.RegisterVerticalLayoutCategory("BuffettForever")
    local function Header(text)
        layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(text))
    end
    Header("BuffettForever |cff9d9d9d" .. L["by Typheous"] .. "|r")

    local minimap = Settings.RegisterAddOnSetting(category, "BuffettForever_MinimapShown", "shown", db.minimap,
        VarType.Boolean, L["Show minimap button"], true)
    Settings.CreateCheckbox(category, minimap, L["The BuffettForever button on the minimap."])
    minimap:SetValueChangedCallback(function(_, value) ns.MinimapButton.SetShown(value) end)

    local function Changed() ns.Fire("SETTINGS_CHANGED") end
    local function Register(key, kind, name)
        local setting = Settings.RegisterAddOnSetting(category, "BuffettForever_" .. key, key, s, kind, name,
            defaults[key])
        setting:SetValueChangedCallback(Changed)
        return setting
    end
    local function Slider(key, name, format, tooltip)
        local range = Options.SLIDERS[key]
        local options = Settings.CreateSliderOptions(range[1], range[2], range[3])
        options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, format)
        Settings.CreateSlider(category, Register(key, VarType.Number, name), options, tooltip)
    end
    -- entries: { value, label, tooltip (optional) }
    local function Dropdown(key, kind, name, entries, tooltip)
        Settings.CreateDropdown(category, Register(key, kind, name), function()
            local container = Settings.CreateControlTextContainer()
            for _, entry in ipairs(entries) do container:Add(entry[1], entry[2], entry[3]) end
            return container:GetData()
        end, tooltip)
    end

    Header(L["Recommendations"])
    Slider("margin", L["Margin of safety"], Pct,
        L["A recipe is recommended only when its ROI is at least this, and the AH is chosen only when it pays this much more than a vendor."])
    local profits = {}
    for _, copper in ipairs(Options.MIN_PROFITS) do
        profits[#profits + 1] = { copper, copper == 0 and L["None"] or ns.Money.Format(copper) }
    end
    Dropdown("minProfit", VarType.Number, L["Minimum profit per craft"], profits,
        L["Recipes that make less than this per craft aren't recommended. 10s suits leveling; 1g or more, level 60."])
    local grades = {}
    for _, grade in ipairs(Options.GRADES) do
        local text = GRADE_TEXT[grade]
        grades[#grades + 1] = { grade, L[text[1]], text[2] and L[text[2]] }
    end
    Dropdown("minGrade", VarType.String, L["Lowest confidence"], grades,
        L["Recommendations may rest on Auction House prices graded this or better. Hover the list's Grade heading for how grades work."])

    Header(L["Costs"])
    local policies = {}
    for _, policy in ipairs(Options.POLICIES) do
        local text = POLICY_TEXT[policy]
        policies[#policies + 1] = { policy, L[text[1]], L[text[2]] }
    end
    Dropdown("ownedPolicy", VarType.String, L["Materials you own"], policies,
        L["What the reagents in your bags and bank count as when a recipe uses them."])
    Slider("cut", L["House cut"], function(v) return ns.Ledger.CutText(v) end, CutTooltip)
    Settings.CreateCheckbox(category, Register("measuredCut", VarType.Boolean, L["Use the cut your sales measure"]),
        L["Once 3 of your sales worth 1g in all have come by mail, use the cut they show instead of the figure above."])
    Slider("saleChance", L["Sale chance"], Pct,
        L["The chance a listing sells before it expires, until your own sales and expiries say otherwise. A listing that doesn't sell loses its deposit."])

    Header(L["Selling on the Auction House"])
    local prices = {}
    for _, rule in ipairs(ns.Post.PRICES) do
        local text = PRICE_TEXT[rule]
        prices[#prices + 1] = { rule, L[text[1]], L[text[2]] }
    end
    Dropdown("postPrice", VarType.String, L["Price"], prices,
        L["What Sell on AH posts what you crafted at, from a search just before it. Gear is priced in whole silver on Forever, so an undercut on gear is at least 1s."])
    local durations = { { 0, L["As the Auction House remembers"] } }
    for d = 1, 3 do durations[#durations + 1] = { d, ns.Deposits.DurationName(d) } end
    Dropdown("depositDuration", VarType.Number, L["Auction length"], durations,
        L["Sell on AH posts for this length, and deposits are figured for it: 5% of the vendor price per 2 hours (8 Hours x4, 24 Hours x12), at least 1s per auction. The Auction House remembers the length you last posted for."])
    Settings.CreateCheckbox(category, Register("postVendorGuard", VarType.Boolean, L["Never below what a vendor pays"]),
        L["Sell on AH refuses a price that brings less after the house cut than a vendor pays for it. Off, it shows such a price in red and lets you post it."])

    Header(L["Price data"])
    Slider("historyDays", L["Price history"], function(v) return string.format(L["%d days"], math.floor(v + 0.5)) end,
        L["Days of prices kept for each item, for fair values, grades and Mr. Market. Fewer days deletes the older ones at your next login."])

    Settings.RegisterAddOnCategory(category)
    ns.settingsCategory = category
    ns.settingsLayout = layout
end

function ns.OpenOptions()
    if not ns.settingsCategory then return end
    ns.RunOutOfCombat(function()
        Settings.OpenToCategory(ns.settingsCategory:GetID())
    end)
end

-- ---------------------------------------------------------------- self test

local function Among(list, value)
    for _, v in ipairs(list) do
        if v == value then return true end
    end
    return false
end

-- Every default is a choice the panel offers: on a slider's range and step, or in a dropdown's list.
function Options.SelfTest(report)
    local d, off = ns.DEFAULT_SETTINGS, {}
    for key, range in pairs(Options.SLIDERS) do
        local v = d[key]
        local step = type(v) == "number" and (v - range[1]) / range[3]
        if not step or v < range[1] or v > range[2] or math.abs(step - math.floor(step + 0.5)) > 1e-6 then
            off[#off + 1] = key
        end
    end
    if not Among(Options.MIN_PROFITS, d.minProfit) then off[#off + 1] = "minProfit" end
    if not Among(Options.GRADES, d.minGrade) then off[#off + 1] = "minGrade" end
    if not Among(Options.POLICIES, d.ownedPolicy) then off[#off + 1] = "ownedPolicy" end
    if not Among({ 0, 1, 2, 3 }, d.depositDuration) then off[#off + 1] = "depositDuration" end
    if type(d.measuredCut) ~= "boolean" then off[#off + 1] = "measuredCut" end
    if not Among(ns.Post.PRICES, d.postPrice) then off[#off + 1] = "postPrice" end
    if type(d.postVendorGuard) ~= "boolean" then off[#off + 1] = "postVendorGuard" end
    table.sort(off)
    local ok = #off == 0
    report("OPTIONS-DEFAULTS", ok, ok and "every default is a choice the settings panel offers"
        or ("not a choice the panel offers: " .. table.concat(off, ", ")))
    return ok and 1 or 0, ok and 0 or 1
end
