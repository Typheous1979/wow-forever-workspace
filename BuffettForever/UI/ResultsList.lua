local addonName, ns = ...

-- The middle pane, in three views (Blizzard's tabs under the window, like the Auction House's;
-- the pane's heading names the view):
-- - Tray: every recipe that uses the tray's reagents (Evaluator.ForTray);
-- - Vendor crafts: recipes you know that profit on vendor prices alone (Evaluator.VendorCrafts);
-- - AH flips: listings in the last full scan below what a vendor pays (Pricing/Flips.lua).
-- One row each:
-- - the columns: the item (with the units; * = a recipe this character knows), cost, best exit
--   (AH or V = vendor), profit, ROI and confidence grade;
-- - click a heading to sort (the ranking by default; again to reverse); click a row for the details;
-- - losses are red, recommended rows white, the rest grey; orange: a vendor craft whose materials
--   would fetch more on the AH;
-- - "Known only" and "Show unconfirmed" filter the Tray view.
-- Also fills the Top pick panel. Re-evaluates (debounced) when the tray, the prices, the known
-- recipes, the sales ledger, the deposits, your bags, vendor prices, the flips or the settings change,
-- while the window is open; otherwise on the next open.

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
local TAB_HANG = 30   -- how far the tabs reach below the window (32 tall, 2 tucked under its edge)

local VIEWS = {   -- label: the tab; title: the pane's heading
    { key = "tray", label = "Tray", title = "Craftable items",
      tip = "Every recipe that uses the reagents in your tray." },
    { key = "vendor", label = "Vendor crafts", title = "Vendor crafts",
      tip = "Recipes you know that profit on vendor prices alone: reagents from a vendor or your bags (counted at what a vendor pays for them), the result sold to a vendor. Certain profit, no Auction House risk." },
    { key = "flips", label = "AH flips", title = "AH flips",
      tip = "Listings in your last full scan priced below what a vendor pays: buy them on the Auction House and sell them to a vendor. Listings vanish fast, so the confidence follows the scan's age." },
}

local window, panel, pick, box, countText, knownCheck, unconfirmedCheck
local tabs = {}
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
    if r.rawBetter then return 1, 0.6, 0.2 end   -- a vendor craft: the materials fetch more on the AH
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
    local mark = r.view and "" or ((r.known and "|cff66ccff*|r " or "") .. (r.vendorOnly and "|cffffd100v|r " or ""))
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
    local function Advice(r)
        local link = ns.Items.Link(r.recipe.output)
        if r.flip then return ns.Flips.Advice(r, link) end
        return ns.Evaluator.Advice(r, link)
    end
    local text
    if top then
        text = Advice(top)
    elseif #ranked > 0 then
        text = L["Nothing meets your margin of safety yet."] .. "\n\n" .. Advice(ranked[1])
    else
        text = L["The best return on investment, and where to sell it, shows here."]
    end
    pick.Text:SetText(text)
    local showMost = richest ~= nil and richest ~= top
    pick.MostTitle:SetShown(showMost)
    pick.MostText:SetShown(showMost)
    if showMost then
        pick.MostText:SetText(string.format(L["%d x %s: +%s (ROI %s, confidence %s)."],
            richest.flip and richest.units or richest.crafts, ns.Items.Link(richest.recipe.output),
            Money.Format(richest.profit), richest.roi and Pct(richest.roi) or L["n/a"], richest.grade))
    end
end

-- The Grade heading explains how grades work (wowf-economics risk-and-recommendation.md).
local function GradeTooltip(owner)
    GameTooltip:SetOwner(owner, "ANCHOR_TOP")
    GameTooltip:SetText(L["Confidence grade: A best, D worst"], 1, 1, 1)
    GameTooltip:AddLine(L["A recipe gets the grade of the weakest Auction House price it relies on. Each price is graded on these tests, and its worst test wins:"],
        nil, nil, nil, true)
    GameTooltip:AddLine(L["Age of the latest scan: A under 24 h, B under 48 h, C under 7 days."], 1, 1, 1, true)
    local s = ns.db.settings
    GameTooltip:AddLine(string.format(L["Days seen in the last %d: A 5 or more, B 3 or more, C 1 or 2; seen in one scan only: D."],
        math.floor(s.historyDays + 0.5)), 1, 1, 1, true)
    GameTooltip:AddLine(L["Day-to-day price swing: A under 15%, B under 30%, C under 60%."], 1, 1, 1, true)
    GameTooltip:AddLine(L["Listed now: A at least twice what you need, B at least what you need, D not enough or none."], 1, 1, 1, true)
    GameTooltip:AddLine(L["Selling into a wall: its cheapest price held 3 days while the quantity never fell: D, until you sell some."],
        1, 1, 1, true)
    GameTooltip:AddLine(string.format(L["Vendor prices are always A. A recipe is recommended only at %s or better (your settings). Scans on more days raise the grades."],
        s.minGrade), 0.6, 0.8, 1, true)
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

local function View()
    return Prefs().view or "tray"
end

-- What the list says when it's empty, by view.
local function EmptyText(view, entries, scanT)
    if view == "vendor" then
        if #ns.RecipeIndex.Known() == 0 then return L["This character knows no recipes yet."] end
        return L["None of your recipes profits on vendor prices with what you carry and what vendors sell. Visiting vendors that sell reagents can find more."]
    elseif view == "flips" then
        if not scanT then return L["Scan at the Auction House to look for listings below what a vendor pays."] end
        return L["No listing in your last full scan was below what a vendor pays."]
    end
    if #entries == 0 then return L["Drop a reagent into the tray to see what it can make, what that costs and what it sells for."] end
    return L["No recipe uses these reagents with these filters."]
end

function ResultsList.Update()
    dirty = false
    if not box then return end
    local view, entries, scanT = View(), ns.Tray.Entries(), nil
    if view == "vendor" then
        ranked = ns.Evaluator.VendorCrafts()
    elseif view == "flips" then
        ranked, scanT = ns.Flips.Results()
    else
        ranked = ns.Evaluator.ForTray(entries, Filter())   -- recipes from vendor goods list even with an empty tray
    end
    ShowRows()
    local recommended = 0
    for _, r in ipairs(ranked) do
        if r.recommended then recommended = recommended + 1 end
    end
    local count = ""
    if view == "flips" and scanT then
        count = string.format(L["%d flips, %d recommended; scanned %s ago"], #ranked, recommended,
            ns.FormatAge(GetServerTime() - scanT))
    elseif #ranked > 0 then
        count = string.format(view == "vendor" and L["%d vendor crafts, %d recommended"] or L["%d recipes, %d recommended"],
            #ranked, recommended)
    end
    countText:SetText(count)
    -- keep the selection when it's still listed, else select the top of the ranking
    local keep
    for _, r in ipairs(ranked) do
        if r.recipe.recipeID == selected then keep = true end
    end
    if not keep then selected = ranked[1] and ranked[1].recipe.recipeID or nil end
    panel.Empty:SetText(EmptyText(view, entries, scanT))
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

-- The tabs show the view and the heading names it; the filters apply to the Tray view only.
local function ShowView()
    if not knownCheck then return end   -- not built yet
    local view = View()
    for i, v in ipairs(VIEWS) do
        if v.key == view then
            PanelTemplates_SetTab(window, i)
            panel.Title:SetText(L[v.title])
        end
    end
    knownCheck:SetShown(view == "tray")
    unconfirmedCheck:SetShown(view == "tray")
end

function ResultsList.SetView(view)
    if View() == view then return end
    Prefs().view = view
    selected = nil
    ShowView()
    ResultsList.Update()
end

-- Blizzard's own tabs (PanelTabButtonTemplate) under the window's bottom edge, where the Auction House keeps
-- Buy, Sell and Auctions; the first sits where the Character frame's does on this frame template. After the
-- views, an Options tab opens Blizzard's settings window at BuffettForever's page (Options.lua) instead of
-- switching the list, so it's never the selected tab (Justin, 2026-10-17: fewer slash commands to learn).
local function Tabs(frame)
    window = frame
    for i, v in ipairs(VIEWS) do
        local tab = CreateFrame("Button", nil, frame, "PanelTabButtonTemplate")
        tab:SetID(i)
        tab:SetText(L[v.label])
        tab:SetScript("OnClick", function()
            PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB)
            ResultsList.SetView(v.key)
        end)
        UI.Tooltip(tab, L[v.label], L[v.tip], "ANCHOR_RIGHT")
        tabs[i] = tab
    end
    local options = CreateFrame("Button", nil, frame, "PanelTabButtonTemplate")
    options:SetID(#VIEWS + 1)
    options:SetText(L["Options"])
    options:SetScript("OnClick", function()
        PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB)
        ns.OpenOptions()
        frame:Lower()   -- the settings window shares this window's strata: let it show on top
    end)
    UI.Tooltip(options, L["Options"],
        L["Margin of safety, minimum profit, the house cut, deposits and price history, in Blizzard's settings window."],
        "ANCHOR_RIGHT")
    tabs[#tabs + 1] = options
    frame.Tabs = tabs   -- PanelTemplates_* find the tabs here (the template's parentArray may fill it too)
    tabs[1]:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 11, 2)
    PanelTemplates_SetNumTabs(frame, #tabs)   -- anchors the rest in a row
    for _, tab in ipairs(tabs) do PanelTemplates_TabResize(tab, 0) end
    frame:SetClampRectInsets(0, 0, 0, -TAB_HANG)   -- dragging the window keeps its tabs on screen
end

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
    Tabs(frame)
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
        GameTooltip:AddLine("|cffff9933" .. L["orange"] .. "|r " .. L["a vendor craft whose materials would fetch more on the AH"],
            1, 1, 1)
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
    knownCheck = UI.Check(panel, L["Known only"], function(on)
        prefs.knownOnly = on
        ResultsList.Update()
    end)
    knownCheck:SetPoint("BOTTOMLEFT", 6, 2)
    knownCheck:SetChecked(prefs.knownOnly)
    unconfirmedCheck = UI.Check(panel, L["Show unconfirmed"], function(on)
        prefs.showUnconfirmed = on
        ResultsList.Update()
    end)
    unconfirmedCheck:SetPoint("LEFT", knownCheck.Text, "RIGHT", 14, 0)
    unconfirmedCheck:SetChecked(prefs.showUnconfirmed)
    UI.Tooltip(unconfirmedCheck, L["Show unconfirmed"],
        L["Also list recipes added after Classic that nobody has confirmed yet: no character of yours knows them and their result hasn't been seen on the Auction House."])
    countText = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    countText:SetPoint("BOTTOMRIGHT", -8, 10)
    ShowView()
    ResultsList.Update()
end

ns.On("MAIN_BUILT", Build)
ns.On("MAIN_SHOWN", function()
    if dirty then ResultsList.Update() end
end)
for _, message in ipairs({ "TRAY_CHANGED", "SCAN_DONE", "RECIPES_KNOWN_CHANGED", "LEDGER_CHANGED", "DEPOSITS_CHANGED",
                           "BAGS_CHANGED", "VENDOR_PRICES_CHANGED", "FLIPS_CHANGED", "SETTINGS_CHANGED" }) do
    ns.On(message, Schedule)
end
