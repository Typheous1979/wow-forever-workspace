local addonName, ns = ...

-- The middle pane: every recipe that uses the tray's reagents, evaluated by
-- Economics/Evaluator.lua, one row each:
-- - the columns: output (with the units made; * = a recipe this character knows), cost, best exit
--   (AH or V = vendor), profit, ROI and confidence grade;
-- - click a heading to sort (the evaluator's ranking by default; again to reverse); click a row
--   for the details pane;
-- - losses are red, recommended rows white, the rest grey;
-- - "Known only" and "Show unconfirmed" filter the list.
-- Also fills the Top pick panel. Re-evaluates (debounced) when the tray, the prices, the known
-- recipes, the sales ledger or the deposits change, while the window is open; otherwise on the next
-- open.

local L = ns.L
local UI = ns.UI
local Money = ns.Money
local ResultsList = {}
ns.ResultsList = ResultsList

local COLUMNS = {   -- left to right, after the item name
    { key = "cost", label = "Cost", width = 64 },
    { key = "best", label = "Best", width = 76 },
    { key = "profit", label = "Profit", width = 64 },
    { key = "roi", label = "ROI", width = 46 },
    { key = "grade", label = "Grade", width = 44 },
}
local BAR_SPACE = 24          -- the scroll bar and the box inset, right of the rows
local QUESTION_MARK = 134400
local GRADE_COLOR = { A = "|cff33ff33", B = "|cffb4ff33", C = "|cffffd100", D = "|cffff5533" }
local DEBOUNCE = 0.15

local panel, pick, box, countText
local results, ranked = {}, {}
local selected
local dirty, pending = true, nil

local function Prefs()
    return ns.charDB.results
end

local function Name(itemID)
    return C_Item.GetItemNameByID(itemID) or ("item " .. itemID)
end

local function Pct(x)
    return string.format("%d%%", math.floor(x * 100 + 0.5))
end

-- ---------------------------------------------------------------- sorting

local function NilLast(a, b, desc)
    if a == nil or b == nil then return a ~= nil end
    if desc then return a > b end
    return a < b
end

local SORTS = {
    name = function(r) return string.lower(Name(r.recipe.output)) end,
    cost = function(r) return r.complete and r.cogs or nil end,
    best = function(r) return r.best end,
    profit = function(r) return r.profit end,
    roi = function(r)
        if not r.profit then return nil end
        return r.roi or math.huge
    end,
    grade = function(r) return ns.Econ.GRADE_RANK[r.grade] end,
}

local function Sort()
    local prefs = Prefs()
    local key, desc = prefs.sortKey, prefs.sortDesc
    local order = {}
    for i, r in ipairs(ranked) do order[r] = i end
    results = {}
    for i, r in ipairs(ranked) do results[i] = r end
    if key == "rank" or not SORTS[key] then
        if not desc then
            for i = 1, math.floor(#results / 2) do
                results[i], results[#results + 1 - i] = results[#results + 1 - i], results[i]
            end
        end
        return
    end
    local value = SORTS[key]
    table.sort(results, function(a, b)
        local va, vb = value(a), value(b)
        if va == vb then return order[a] < order[b] end
        return NilLast(va, vb, desc)
    end)
end

-- ---------------------------------------------------------------- rows

local function Color(r)
    if r.profit and r.profit < 0 then return 1, 0.35, 0.35 end
    if r.recommended then return 1, 1, 1 end
    return 0.6, 0.6, 0.6
end

local function InitRow(row, data)
    UI.SetupRow(row)
    if not row.icon then
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(16, 16)
        row.icon:SetPoint("LEFT", 4, 0)
        row.cols = {}
        local x = -4
        for i = #COLUMNS, 1, -1 do
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetPoint("RIGHT", x, 0)
            fs:SetWidth(COLUMNS[i].width - 4)
            fs:SetJustifyH("RIGHT")
            fs:SetWordWrap(false)
            row.cols[i] = fs
            x = x - COLUMNS[i].width
        end
        row.left:ClearAllPoints()
        row.left:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
        row.left:SetPoint("RIGHT", row, "RIGHT", x - 4, 0)
        row.left:SetFontObject("GameFontHighlightSmall")
        row.right:SetText("")
        row:SetScript("OnClick", function(self) ResultsList.Select(self.recipeID) end)
        row:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(self.output)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(L["Click for the details."], 1, 0.82, 0)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", GameTooltip_Hide)
    end
    local r = data.result
    row.recipeID, row.output = r.recipe.recipeID, r.recipe.output
    row.icon:SetTexture(C_Item.GetItemIconByID(r.recipe.output) or QUESTION_MARK)
    local mark = (r.known and "|cff66ccff*|r " or "") .. (r.vendorOnly and "|cffffd100v|r " or "")
    row.left:SetText(string.format("%s%s x%d", mark, Name(r.recipe.output), r.units))
    local cR, cG, cB = Color(r)
    row.left:SetTextColor(cR, cG, cB)
    local values = {
        r.complete and Money.Compact(r.cogs) or "?",
        r.best and ((r.bestSource == "ah" and L["AH"] or L["V"]) .. " " .. Money.Compact(r.best)) or "-",
        r.profit and Money.Compact(r.profit) or "?",
        r.roi and Pct(r.roi) or (r.profit and L["n/a"] or "-"),
        (GRADE_COLOR[r.grade] or "") .. r.grade .. "|r",
    }
    for i, fs in ipairs(row.cols) do
        fs:SetText(values[i])
        fs:SetTextColor(cR, cG, cB)
    end
    row.selected:SetShown(r.recipe.recipeID == selected)
end

local function Repaint()
    if not box then return end
    box:ForEachFrame(function(row, data) InitRow(row, data) end)
    if panel then panel.Empty:SetShown(#results == 0) end
end

-- ---------------------------------------------------------------- top pick

local function UpdateTopPick()
    if not pick then return end
    local top, richest
    for _, r in ipairs(ranked) do
        if r.recommended then
            top = top or r
            if not richest or r.profit > richest.profit then richest = r end
        end
    end
    local Ev = ns.Evaluator
    local text
    if top then
        text = Ev.Advice(top, ns.Items.Link(top.recipe.output))
    elseif #ranked > 0 then
        text = L["Nothing meets your margin of safety yet."] .. "\n\n" ..
            Ev.Advice(ranked[1], ns.Items.Link(ranked[1].recipe.output))
    else
        text = L["The best return on investment, and where to sell it, shows here."]
    end
    pick.Text:SetText(text)
    local showMost = richest ~= nil and richest ~= top
    pick.MostTitle:SetShown(showMost)
    pick.MostText:SetShown(showMost)
    if showMost then
        pick.MostText:SetText(string.format(L["%d x %s: +%s (ROI %s, confidence %s)."], richest.crafts,
            ns.Items.Link(richest.recipe.output), Money.Format(richest.profit),
            richest.roi and Pct(richest.roi) or L["n/a"], richest.grade))
    end
end

-- The Grade heading explains how grades work (wowf-economics risk-and-recommendation.md).
local function GradeTooltip(owner)
    GameTooltip:SetOwner(owner, "ANCHOR_TOP")
    GameTooltip:SetText(L["Confidence grade: A best, D worst"], 1, 1, 1)
    GameTooltip:AddLine(L["A recipe gets the grade of the weakest Auction House price it relies on. Each price is graded on four tests, and its worst test wins:"],
        nil, nil, nil, true)
    GameTooltip:AddLine(L["Age of the latest scan: A under 24 h, B under 48 h, C under 7 days."], 1, 1, 1, true)
    GameTooltip:AddLine(L["Days seen in the last 14: A 5 or more, B 3 or more, C 1 or 2; seen in one scan only: D."], 1, 1, 1, true)
    GameTooltip:AddLine(L["Day-to-day price swing: A under 15%, B under 30%, C under 60%."], 1, 1, 1, true)
    GameTooltip:AddLine(L["Listed now: A at least twice what you need, B at least what you need, D not enough or none."], 1, 1, 1, true)
    GameTooltip:AddLine(L["Vendor prices are always A. A recipe is recommended only at C or better. Scans on more days raise the grades."],
        0.6, 0.8, 1, true)
    GameTooltip:AddLine(L["Click to sort; click again to reverse."], 1, 0.82, 0)
    GameTooltip:Show()
end

-- ---------------------------------------------------------------- update

local function Filter()
    local prefs = Prefs()
    return { known = prefs.knownOnly and "char" or nil, confirmed = not prefs.showUnconfirmed }
end

function ResultsList.Select(recipeID)
    selected = recipeID
    local result
    for _, r in ipairs(results) do
        if r.recipe.recipeID == recipeID then result = r end
    end
    ns.DetailPanel.Show(result)
    Repaint()
end

-- The rows in the current sort order (no re-evaluation).
local function ShowRows()
    Sort()
    local dp = CreateDataProvider()
    for i, r in ipairs(results) do dp:Insert({ result = r, index = i }) end
    box:SetDataProvider(dp, ScrollBoxConstants.RetainScrollPosition)
end

function ResultsList.Update()
    dirty = false
    if not box then return end
    local entries = ns.Tray.Entries()
    ranked = ns.Evaluator.ForTray(entries, Filter())   -- recipes from vendor goods list even with an empty tray
    ShowRows()
    local recommended = 0
    for _, r in ipairs(ranked) do
        if r.recommended then recommended = recommended + 1 end
    end
    countText:SetText(#ranked > 0 and string.format(L["%d recipes, %d recommended"], #ranked, recommended) or "")
    -- keep the selection when it's still listed, else select the top of the ranking
    local keep
    for _, r in ipairs(ranked) do
        if r.recipe.recipeID == selected then keep = true end
    end
    if not keep then selected = ranked[1] and ranked[1].recipe.recipeID or nil end
    panel.Empty:SetText(#entries == 0
        and L["Drop a reagent into the tray to see what it can make, what that costs and what it sells for."]
        or L["No recipe uses these reagents with these filters."])
    ResultsList.Select(selected)
    UpdateTopPick()
    -- names and icons may still be loading: repaint when they're in
    local ids = {}
    for _, r in ipairs(ranked) do
        ids[#ids + 1] = r.recipe.output
        for _, line in ipairs(r.lines) do ids[#ids + 1] = line.itemID end
    end
    if #ids > 0 then
        ns.Items.Load(ids, function()
            if Prefs().sortKey == "name" then ShowRows() else Repaint() end
            ns.DetailPanel.Refresh()
            UpdateTopPick()
        end)
    end
end

local function Schedule()
    dirty = true
    if not box or not ns.Main.IsShown() or pending then return end
    pending = C_Timer.NewTimer(DEBOUNCE, function()
        pending = nil
        ResultsList.Update()
    end)
end

-- ---------------------------------------------------------------- build

local function Header(parent, text, key, anchorPoint, x, width, justify)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(width, 14)
    b:SetPoint(anchorPoint, x, -28)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.text:SetAllPoints()
    b.text:SetJustifyH(justify)
    b.text:SetText(text)
    b:SetScript("OnClick", function()
        local prefs = Prefs()
        if prefs.sortKey == key then
            prefs.sortDesc = not prefs.sortDesc
        else
            prefs.sortKey, prefs.sortDesc = key, key ~= "name" and key ~= "cost"
        end
        if box then ShowRows() end
    end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(L["Click to sort; click again to reverse."], 1, 1, 1)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
    return b
end

local function Build(frame)
    panel, pick = frame.Results, frame.Pick
    local x = -BAR_SPACE - 4
    for i = #COLUMNS, 1, -1 do
        local c = COLUMNS[i]
        local header = Header(panel, L[c.label], c.key, "TOPRIGHT", x, c.width - 4, "RIGHT")
        if c.key == "grade" then header:SetScript("OnEnter", GradeTooltip) end
        x = x - c.width
    end
    local nameHeader = Header(panel, L["Item"], "name", "TOPLEFT", 28, 120, "LEFT")
    nameHeader:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(L["Item"], 1, 1, 1)
        GameTooltip:AddLine(L["The default order is the evaluator's ranking: recommended first, then by ROI. Click to sort by name."],
            nil, nil, nil, true)
        GameTooltip:AddLine("|cff66ccff*|r " .. L["a recipe this character knows"], 1, 1, 1)
        GameTooltip:AddLine("|cffffd100v|r " .. L["made entirely from goods a vendor sells"], 1, 1, 1)
        GameTooltip:Show()
    end)

    local holder = CreateFrame("Frame", nil, panel)
    holder:SetPoint("TOPLEFT", 2, -44)
    holder:SetPoint("BOTTOMRIGHT", -2, 30)
    local view = CreateScrollBoxListLinearView(2, 2, 2, 2, 0)
    view:SetElementExtent(UI.ROW_HEIGHT)
    view:SetElementInitializer("Button", InitRow)
    box = UI.ScrollList(holder, view)

    local prefs = Prefs()
    local known = UI.Check(panel, L["Known only"], function(on)
        prefs.knownOnly = on
        ResultsList.Update()
    end)
    known:SetPoint("BOTTOMLEFT", 6, 2)
    known:SetChecked(prefs.knownOnly)
    local unconfirmed = UI.Check(panel, L["Show unconfirmed"], function(on)
        prefs.showUnconfirmed = on
        ResultsList.Update()
    end)
    unconfirmed:SetPoint("LEFT", known.Text, "RIGHT", 14, 0)
    unconfirmed:SetChecked(prefs.showUnconfirmed)
    UI.Tooltip(unconfirmed, L["Show unconfirmed"],
        L["Also list recipes added after Classic that nobody has confirmed yet: no character of yours knows them and their result hasn't been seen on the Auction House."])
    countText = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    countText:SetPoint("BOTTOMRIGHT", -8, 10)
    ResultsList.Update()
end

ns.On("MAIN_BUILT", Build)
ns.On("MAIN_SHOWN", function()
    if dirty then ResultsList.Update() end
end)
for _, message in ipairs({ "TRAY_CHANGED", "SCAN_DONE", "RECIPES_KNOWN_CHANGED", "LEDGER_CHANGED", "DEPOSITS_CHANGED" }) do
    ns.On(message, Schedule)
end
