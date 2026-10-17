local addonName, ns = ...

-- The right pane: the selected recipe in full ("show your work", wowf-economics), as data:
-- - what it makes, for which profession, and who knows it;
-- - each reagent: the units owned (valued at what they'd sell for) and the units bought, from which
--   source (Vendor, AH, Craft), and what that costs;
-- - Sell: the vendor and AH exits for the batch, the AH's parts (price, cut, deposit, sale chance),
--   the listings behind the price and your own;
-- - Result: where to sell, profit, ROI, value added, confidence; then the verdict.
-- Numbers sit in label/value rows; each row's tooltip says where its number comes from (Justin,
-- 2026-10-17: data, not paragraphs). The pane scrolls (ScrollFrameTemplate).

local L = ns.L
local Money = ns.Money
local DetailPanel = {}
ns.DetailPanel = DetailPanel

local WIDTH = 222               -- the pane is 260 wide: scroll bar and margins take the rest
local LABEL_WIDTH = 92          -- row labels; values are right-aligned in the rest
local INDENT = 10               -- the AH's parts sit under it
local ROW_HEIGHT = 14
local WALL = 5                  -- this many listings or more, all at one price: perhaps a single seller
local GAP, HEADING_GAP, HEADING_AFTER = 3, 12, 5
local GOLD, GREEN, ORANGE, RED, BLUE, GREY = "|cffffd100", "|cff33ff33", "|cffff9933", "|cffff5533", "|cff66ccff", "|cff999999"
local SOURCE_COLOR = { vendor = GOLD, ah = BLUE, craft = "|cffff88ff" }
local SOURCE_TEXT = { vendor = "Vendor", ah = "AH", craft = "Craft" }
local GRADE_COLOR = { A = GREEN, B = "|cffb4ff33", C = GOLD, D = RED }

local panel, scroll, child, current
local lines, rows = {}, {}
local usedLines, usedRows, height, nextGap, last = 0, 0, 0, 0, nil

-- Put a line or a row under the previous one; gap = space above it.
local function Place(region, regionHeight, gap)
    gap = (gap or GAP) + nextGap
    nextGap = 0
    region:ClearAllPoints()
    if last then
        region:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -gap)
    else
        region:SetPoint("TOPLEFT", child, "TOPLEFT", 2, 0)
        gap = 0
    end
    last = region
    height = height + gap + regionHeight
end

-- One line of text (wraps).
local function Add(text, font, gap)
    usedLines = usedLines + 1
    local fs = lines[usedLines]
    if not fs then
        fs = child:CreateFontString(nil, "OVERLAY")
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(true)
        fs:SetWidth(WIDTH)
        lines[usedLines] = fs
    end
    fs:SetFontObject(font or "GameFontHighlightSmall")
    fs:SetText(text)
    fs:Show()
    Place(fs, fs:GetStringHeight(), gap)
end

local function Heading(text)
    Add(text, "GameFontNormal", HEADING_GAP)
    nextGap = HEADING_AFTER
end

local function ShowTip(self)
    if not self.tip or #self.tip == 0 then return end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText(self.label:GetText(), 1, 1, 1)
    for _, text in ipairs(self.tip) do GameTooltip:AddLine(text, nil, nil, nil, true) end
    GameTooltip:Show()
end

-- A label/value row; tip = the tooltip's lines (optional); sub = indented under the row above.
local function Row(label, value, tip, sub)
    usedRows = usedRows + 1
    local row = rows[usedRows]
    if not row then
        row = CreateFrame("Frame", nil, child)
        row:SetSize(WIDTH, ROW_HEIGHT)
        row.label = row:CreateFontString(nil, "OVERLAY")
        row.label:SetJustifyH("LEFT")
        row.label:SetWordWrap(false)
        row.value = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.value:SetJustifyH("RIGHT")
        row.value:SetWordWrap(false)
        row.value:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        row.value:SetWidth(WIDTH - LABEL_WIDTH)
        row:SetMouseMotionEnabled(true)
        row:SetScript("OnEnter", ShowTip)
        row:SetScript("OnLeave", GameTooltip_Hide)
        rows[usedRows] = row
    end
    local indent = sub and INDENT or 0
    row.label:ClearAllPoints()
    row.label:SetPoint("LEFT", row, "LEFT", indent, 0)
    row.label:SetWidth(LABEL_WIDTH - indent)
    row.label:SetFontObject(sub and "GameFontHighlightSmall" or "GameFontNormalSmall")
    row.label:SetText(label)
    row.value:SetText(value)
    row.tip = tip
    row:Show()
    Place(row, ROW_HEIGHT, sub and 1 or nil)
end

local function Pct(x)
    return string.format("%d%%", math.floor(x * 100 + 0.5))
end

local function Coins(copper)
    if copper > 0 and copper < 1 then return L["under 1c"] end
    return Money.Compact(copper)
end

local function ReagentLine(line)
    local parts = {}
    if line.owned > 0 then
        parts[#parts + 1] = string.format(L["%d owned (%s)"], line.owned, Money.Compact(line.ownedCost))
    end
    if line.rest > 0 then
        if line.source then
            parts[#parts + 1] = string.format("%d %s%s|r (%s)", line.rest, SOURCE_COLOR[line.source],
                L[SOURCE_TEXT[line.source]], Money.Compact(line.buyCost))
        else
            parts[#parts + 1] = string.format("%d %s%s|r", line.rest, RED, L["no price"])
        end
    end
    return string.format("%d x %s: %s", line.need, ns.Items.Link(line.itemID), table.concat(parts, ", "))
end

-- Why the recipe has its grade: the weakest price it relies on and the test that set it.
local function GradeReason(why)
    if not why then return L["Every price it relies on is solid."] end
    local link, info = ns.Items.Link(why.itemID), why.info or {}
    if why.reason == "age" then
        return string.format(L["The latest scan of %s is %s old (A under 24 h, B under 48 h, C under 7 days)."], link,
            ns.FormatAge(info.age))
    elseif why.reason == "single" then
        return string.format(L["%s has been seen in one scan only."], link)
    elseif why.reason == "days" then
        return string.format(L["%s has %d day(s) of data (B needs 3, A needs 5)."], link, info.days or 0)
    elseif why.reason == "volatile" then
        return string.format(L["%s swings %s from day to day (A under 15%%, B under 30%%, C under 60%%)."], link,
            info.cv and Pct(info.cv) or "?")
    elseif why.reason == "depth" then
        return string.format(L["Only %d %s listed for the %d needed (A wants twice that)."], info.listed or 0, link,
            why.need or 0)
    end
    return string.format(L["No %s listed now."], link)
end

-- ---------------------------------------------------------------- Sell

-- The AH's parts: price, cut, deposit, sale chance (sub-rows of the AH row).
local function AHParts(r)
    local itemID, units = r.recipe.output, r.units
    if r.ahPrice then
        Row(L["Price"], string.format(L["%s each"], Money.Compact(r.ahPrice)), {
            L["The lower of the market value and the cheapest listing (the fair value once the last scan is over 48 hours old), and never above what a vendor charges for it."],
        }, true)
    end
    local cut, measured, sales = ns.Ledger.Cut()
    Row(L["Cut"], measured and string.format("%.1f%%", cut * 100) or Pct(cut), {
        measured and string.format(L["Measured from %d of your sales."], sales)
            or string.format(L["The default until %d of your sales worth 1g in all measure it."], ns.Econ.CUT_MIN_SALES),
    }, true)

    local D = ns.Deposits
    local commodity, duration = D.IsCommodity(itemID), D.DurationName()
    local deposit = r.ahDeposit or D.PerUnit(itemID, units)
    local auction = commodity and deposit * units or deposit
    local p, sold, expired, market = ns.Ledger.SaleChance(itemID)
    local tip = {
        commodity and string.format(L["One auction of all %d for %s: %s (%s each)."], units, duration, Coins(auction), Coins(deposit))
            or string.format(L["One auction each for %s: %s apiece."], duration, Coins(deposit)),
        L["Returned when it sells, lost when it expires. Forever charges 5% of the vendor price per 2 hours (8 Hours x4, 24 Hours x12), at least 1s per auction."],
    }
    if math.abs(auction - ns.Econ.DEPOSIT_MIN) < 0.01 then
        tip[#tip + 1] = commodity and L["This is the 1s minimum: a bigger batch spreads it."] or L["This is the 1s minimum."]
    end
    if deposit > 0 and p < 1 then
        tip[#tip + 1] = string.format(L["Expected loss: %s per unit sold, at a %s sale chance."], Coins(deposit * (1 - p) / p), Pct(p))
    end
    Row(L["Deposit"], commodity and (units > 1 and string.format(L["%s for %d"], Coins(auction), units) or Coins(auction))
        or string.format(L["%s each"], Coins(deposit)), tip, true)

    Row(L["Sale chance"], sold + expired > 0 and string.format("%s (%d/%d)", Pct(p), sold, sold + expired) or Pct(p), {
        sold + expired > 0 and string.format(L["%d of your %d sold (cancelled ones don't count), pulled toward your rate over all items: %s."],
            sold, sold + expired, Pct(market))
            or string.format(L["None of yours has sold or expired yet, so your rate over all items: %s."], Pct(market)),
    }, true)
end

-- The listings behind the AH price; orange when every listing is at one price.
local function Listed(itemID)
    local row, age = ns.PriceDB.Get(itemID)
    if not row then return end
    local ladder = ns.PriceDB.UnpackLadder(row.ladder)
    local _, days = ns.PriceDB.History(row)
    local lo, hi = ladder[1] or row.min, ladder[#ladder - 1] or row.min
    local prices = lo == hi and Money.Compact(lo) or string.format(L["%s to %s"], Money.Compact(lo), Money.Compact(hi))
    local wall = #ladder == 2 and (row.n or 0) >= WALL
    local tip = { string.format(L["%s listed at %s; %d day(s) of data; the last scan was %s ago."],
        BreakUpLargeNumbers(row.q or 0), prices, days, ns.FormatAge(age)) }
    if wall then tip[#tip + 1] = ORANGE .. L["Every listing is at one price: perhaps a single seller, so demand is unproven."] .. "|r" end
    Row(L["Listed"], (wall and ORANGE or "") .. string.format(L["%s at %s"], BreakUpLargeNumbers(row.q or 0), prices)
        .. (wall and "|r" or ""), tip)
end

-- Your own auctions and sales of the item, when there are any.
local function Yours(itemID)
    local listed = ns.Ledger.Listed(itemID) or 0
    local item = ns.Ledger.Item(itemID)
    local sold = item and item.s or 0
    if listed == 0 and sold == 0 then return end
    local parts, tip = {}, {}
    if listed > 0 then
        parts[#parts + 1] = string.format(L["%d listed"], listed)
        tip[#tip + 1] = string.format(L["%d listed at your last visit to the Auction House."], listed)
    end
    if sold > 0 then
        parts[#parts + 1] = string.format(L["%d sold"], sold)
        tip[#tip + 1] = string.format(L["%d sold, at %s each on average."], sold, Money.Format(item.bid / sold))
    end
    Row(L["Yours"], table.concat(parts, ", "), tip)
end

local function Sell(r)
    local recipe = r.recipe
    Heading(L["Sell"])
    Row(L["Vendor"], r.vendorExit and Money.Compact(r.vendorExit) or (GREY .. L["won't buy"] .. "|r"), {
        r.vendorExit and string.format(L["What a vendor pays for the batch (%s each): certain and instant."],
            Money.Format(r.vendorExit / r.units)) or L["A vendor won't buy it."],
    })
    if recipe.bop then
        Row(L["AH"], GREY .. L["binds on pickup"] .. "|r", { L["It binds when picked up, so it can't be sold on the AH."] })
    elseif r.ahExit then
        local value = r.ahExit > 0 and Money.Compact(r.ahExit) or (ORANGE .. L["none"] .. "|r")
        Row(L["AH"], value, {
            string.format(L["What the batch nets: (price - cut - expected deposit loss) x %d, %s each."], r.units,
                Money.Format(r.ahUnit)),
            r.ahExit == 0 and (ORANGE .. L["The deposits it would likely lose outweigh its price."] .. "|r") or nil,
        })
        AHParts(r)
        Listed(recipe.output)
    else
        Row(L["AH"], GREY .. L["no price"] .. "|r", { L["Scan at the Auction House."] })
    end
    Yours(recipe.output)
end

-- ---------------------------------------------------------------- Result and verdict

local function Result(r)
    local s = ns.db.settings
    Heading(L["Result"])
    local sellTip = { string.format(L["The AH is chosen only when it beats the vendor by your %s margin of safety."], Pct(s.margin)) }
    if r.underMargin then
        sellTip[#sellTip + 1] = string.format(L["Here the AH pays more, but by only %s."], Pct(r.ahExit / r.vendorExit - 1))
    end
    Row(L["Sell to"], r.bestSource == "ah" and L["AH"] or (r.bestSource == "vendor" and L["Vendor"] or "-"), sellTip)
    if r.profit then
        Row(L["Profit"], (r.profit < 0 and RED or GREEN) .. Money.Compact(r.profit) .. "|r", {
            string.format(L["The best exit minus the cost of the reagents, for the batch (%s per craft)."],
                Money.Format(r.profit / r.crafts)),
        })
        Row(L["ROI"], r.roi and Pct(r.roi) or L["n/a"], { L["Profit / cost. n/a when the reagents cost nothing."] })
    else
        Row(L["Profit"], "?", { L["Unknown: a reagent or the result has no price."] })
    end
    if r.valueAdded then
        Row(L["Value added"], (r.valueAdded < 0 and RED or "") .. Money.Compact(r.valueAdded) .. (r.valueAdded < 0 and "|r" or ""), {
            string.format(L["The best exit minus what all the reagents would fetch if you sold them instead (%s). Below 0: sell the materials."],
                Money.Format(r.liquidation)),
        })
    end
    Row(L["Confidence"], (GRADE_COLOR[r.grade] or "") .. r.grade .. "|r", {
        GradeReason(r.gradeWhy),
        L["A recipe gets the grade of the weakest Auction House price it relies on."],
    })
end

local function Verdict(r)
    Heading(L["Verdict"])
    if r.recommended then
        local where = r.bestSource == "ah" and L["sell on the AH"] or L["sell to a vendor"]
        Add(GREEN .. string.format(L["Recommended: craft %d, %s."], r.crafts, where) .. "|r")
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
end

-- ---------------------------------------------------------------- refresh

function DetailPanel.Refresh()
    if not panel then return end
    for i = 1, usedLines do lines[i]:Hide() end
    for i = 1, usedRows do rows[i]:Hide() end
    usedLines, usedRows, height, nextGap, last = 0, 0, 0, 0, nil
    local r = current
    panel.Text:SetShown(r == nil)
    scroll:SetShown(r ~= nil)
    if not r then return end
    local recipe = r.recipe

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
    Row(L["Cost"], r.complete and Money.Compact(r.cogs) or "?", {
        L["Reagents you own count at what they'd sell for; the rest come from the cheapest of a vendor, the AH or a recipe you know."],
    })

    Sell(r)
    Result(r)
    Verdict(r)
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
