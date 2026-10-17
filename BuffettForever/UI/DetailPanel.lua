local addonName, ns = ...

-- The right pane: the selected recipe in full ("show your work", wowf-economics):
-- - what it makes, for which profession, and who knows it;
-- - each reagent: the units owned (valued at what they'd sell for) and the units bought, from which
--   source (Vendor, AH, Craft), and what that costs;
-- - the exits: a vendor, and the AH after the cut, with the market depth behind the AH price (how
--   many are listed, at what prices, over how many days of data), flagging a wall of identical asks
--   (asking prices aren't sales);
-- - profit, ROI, value added, the confidence grade with the price and the test that set it, and the
--   verdict with its reasons.
-- The lines sit in a scroll frame (ScrollFrameTemplate), so a long recipe scrolls instead of
-- running off the pane. Section headings get space above and below.

local L = ns.L
local Money = ns.Money
local DetailPanel = {}
ns.DetailPanel = DetailPanel

local WIDTH = 222               -- the pane is 260 wide: scroll bar and margins take the rest
local WALL = 5                  -- this many listings or more, all at one price: perhaps a single seller
local GAP, HEADING_GAP, HEADING_AFTER = 3, 12, 5
local GOLD, GREEN, ORANGE, RED, BLUE = "|cffffd100", "|cff33ff33", "|cffff9933", "|cffff5533", "|cff66ccff"
local SOURCE_COLOR = { vendor = GOLD, ah = BLUE, craft = "|cffff88ff" }
local SOURCE_TEXT = { vendor = "Vendor", ah = "AH", craft = "Craft" }
local GRADE_COLOR = { A = GREEN, B = "|cffb4ff33", C = GOLD, D = RED }

local panel, scroll, child, current
local lines, used, height = {}, 0, 0
local nextGap = 0

-- One line of text; gap = space above it.
local function Add(text, font, gap)
    used = used + 1
    local fs = lines[used]
    if not fs then
        fs = child:CreateFontString(nil, "OVERLAY")
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(true)
        fs:SetWidth(WIDTH)
        lines[used] = fs
    end
    gap = (gap or GAP) + nextGap
    nextGap = 0
    fs:ClearAllPoints()
    if used == 1 then
        fs:SetPoint("TOPLEFT", child, "TOPLEFT", 2, 0)
        gap = 0
    else
        fs:SetPoint("TOPLEFT", lines[used - 1], "BOTTOMLEFT", 0, -gap)
    end
    fs:SetFontObject(font or "GameFontHighlightSmall")
    fs:SetText(text)
    fs:Show()
    height = height + gap + fs:GetStringHeight()
end

local function Heading(text)
    Add(text, "GameFontNormal", HEADING_GAP)
    nextGap = HEADING_AFTER
end

local function Pct(x)
    return string.format("%d%%", math.floor(x * 100 + 0.5))
end

-- "8 listed at 90s to 1g; 1 day of data, 2 h old." and whether all listings share one price.
local function Depth(itemID)
    local row, age = ns.PriceDB.Get(itemID)
    if not row then return nil end
    local ladder = ns.PriceDB.UnpackLadder(row.ladder)
    local _, days = ns.PriceDB.History(row)
    local lo, hi = ladder[1] or row.min, ladder[#ladder - 1] or row.min
    local prices = lo == hi and Money.Compact(lo) or string.format(L["%s to %s"], Money.Compact(lo), Money.Compact(hi))
    local text = string.format(L["%s listed at %s; %d day(s) of data, %s old."], BreakUpLargeNumbers(row.q or 0), prices,
        days, ns.FormatAge(age))
    local wall = #ladder == 2 and (row.n or 0) >= WALL
    return text, wall
end

local function ReagentLine(line)
    local parts = {}
    if line.owned > 0 then
        parts[#parts + 1] = string.format(L["%d owned (%s)"], line.owned, Money.Format(line.ownedCost))
    end
    if line.rest > 0 then
        if line.source then
            parts[#parts + 1] = string.format("%d %s%s|r (%s)", line.rest, SOURCE_COLOR[line.source],
                L[SOURCE_TEXT[line.source]], Money.Format(line.buyCost))
        else
            parts[#parts + 1] = string.format("%d %s%s|r", line.rest, RED, L["no price"])
        end
    end
    return string.format("%d x %s: %s", line.need, ns.Items.Link(line.itemID), table.concat(parts, ", "))
end

-- Why the recipe has its grade: the weakest price it relies on and the test that set it.
local function GradeReason(why)
    if not why then return L["every price it relies on is solid."] end
    local link, info = ns.Items.Link(why.itemID), why.info or {}
    if why.reason == "age" then
        return string.format(L["the latest scan of %s is %s old (A under 24 h, B under 48 h, C under 7 days)."], link,
            ns.FormatAge(info.age))
    elseif why.reason == "single" then
        return string.format(L["%s has been seen in one scan only."], link)
    elseif why.reason == "days" then
        return string.format(L["%s has %d day(s) of data (B needs 3, A needs 5)."], link, info.days or 0)
    elseif why.reason == "volatile" then
        return string.format(L["%s swings %s from day to day (A under 15%%, B under 30%%, C under 60%%)."], link,
            info.cv and Pct(info.cv) or "?")
    elseif why.reason == "depth" then
        return string.format(L["only %d %s listed for the %d needed (A wants twice that)."], info.listed or 0, link,
            why.need or 0)
    end
    return string.format(L["no %s listed now."], link)
end

function DetailPanel.Refresh()
    if not panel then return end
    for i = 1, used do lines[i]:Hide() end
    used, height, nextGap = 0, 0, 0
    local r = current
    panel.Text:SetShown(r == nil)
    scroll:SetShown(r ~= nil)
    if not r then return end
    local recipe, s = r.recipe, ns.db.settings

    Add(string.format("%s x%d", ns.Items.Link(recipe.output), r.units), "GameFontNormal")
    local about = { string.format("%s (%d/%d)", ns.RecipeIndex.ProfessionName(recipe.profession), recipe.yellow, recipe.grey) }
    if r.known then
        about[#about + 1] = BLUE .. L["you know it"] .. "|r"
    elseif ns.RecipeIndex.IsKnown(recipe.recipeID, "any") then
        about[#about + 1] = L["one of your characters knows it"]
    else
        about[#about + 1] = L["not known"]
    end
    if recipe.new then
        about[#about + 1] = ns.RecipeIndex.IsConfirmed(recipe.recipeID) and L["new since Classic"]
            or (ORANGE .. L["new, unconfirmed"] .. "|r")
    end
    if r.crafts > 1 then about[#about + 1] = string.format(L["%d crafts"], r.crafts) end
    Add(table.concat(about, ", "))
    if r.vendorOnly then Add(GOLD .. L["Made entirely from goods a vendor sells."] .. "|r") end

    Heading(L["Reagents"])
    for _, line in ipairs(r.lines) do Add(ReagentLine(line)) end
    Add(string.format(L["Cost: %s"], r.complete and Money.Format(r.cogs) or "?"), nil, 6)

    Heading(L["Sell"])
    Add(string.format(L["Vendor: %s"], r.vendorExit and Money.Format(r.vendorExit) or L["a vendor won't buy it"]))
    if recipe.bop then
        Add(L["AH: binds on pickup, so it can't be sold there."])
    elseif r.ahExit then
        Add(string.format(L["AH: %s after the %d%% cut (deposits not counted yet)."], Money.Format(r.ahExit),
            math.floor(s.cut * 100 + 0.5)))
        local depth, wall = Depth(recipe.output)
        if depth then Add("    " .. depth, nil, 2) end
        if wall then
            Add("    " .. ORANGE .. L["Every listing is at one price: perhaps a single seller, so demand is unproven."] .. "|r",
                nil, 2)
        end
    else
        Add(L["AH: no price yet. Scan at the Auction House."])
    end
    if r.underMargin then
        Add(string.format(L["The AH pays more, but not by your %s margin of safety: the vendor wins."], Pct(s.margin)))
    end

    Heading(L["Result"])
    if r.profit then
        local color = r.profit < 0 and RED or GREEN
        Add(string.format(L["Profit: %s%s|r (ROI %s)"], color, Money.Format(r.profit), r.roi and Pct(r.roi) or L["n/a"]))
    else
        Add(L["Profit: unknown"])
    end
    if r.valueAdded then
        Add(string.format(L["Value added over selling the materials: %s"], Money.Format(r.valueAdded)))
    end
    Add(string.format(L["Confidence %s%s|r: %s"], GRADE_COLOR[r.grade] or "", r.grade, GradeReason(r.gradeWhy)))

    Heading(L["Verdict"])
    if r.recommended then
        Add(GREEN .. L["Recommended."] .. "|r " .. ns.Evaluator.Advice(r, ns.Items.Link(recipe.output)))
    else
        local why = {}
        for _, key in ipairs(r.reasons) do why[#why + 1] = ns.Evaluator.ReasonText(key) end
        Add(ORANGE .. L["Not recommended:"] .. "|r " .. table.concat(why, ", ") .. ".")
    end
    for _, w in ipairs(r.warnings) do
        if w[1] == "cantFill" then
            Add(string.format(L["Only %d of %s listed; this batch needs %d."], w[3], ns.Items.Link(w[2]), w[4]))
        elseif w[1] == "noPrice" then
            Add(string.format(L["No price for %s: scan at the Auction House, or visit a vendor that sells it."],
                ns.Items.Link(w[2])))
        elseif w[1] == "unknownValue" then
            Add(string.format(L["What your %s is worth is unknown."], ns.Items.Link(w[2])))
        end
    end
    child:SetHeight(math.max(1, height + 8))
end

-- result: an Evaluator result, or nil for the placeholder text.
function DetailPanel.Show(result)
    local changed = result ~= current
    current = result
    DetailPanel.Refresh()
    if changed and scroll then scroll:SetVerticalScroll(0) end
end

ns.On("MAIN_BUILT", function(frame)
    panel = frame.Details
    scroll = CreateFrame("ScrollFrame", nil, panel, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 8, -28)
    scroll:SetPoint("BOTTOMRIGHT", -26, 8)
    scroll.ScrollBar:SetHideIfUnscrollable(true)
    child = CreateFrame("Frame", nil, scroll)
    child:SetSize(WIDTH + 4, 1)
    scroll:SetScrollChild(child)
    DetailPanel.Refresh()
end)
