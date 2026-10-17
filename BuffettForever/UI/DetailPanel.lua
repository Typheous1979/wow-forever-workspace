local addonName, ns = ...

-- The right pane: the selected recipe in full ("show your work", wowf-economics), as data:
-- - what it makes, for which profession, and who knows it: the result's round icon (with the count)
--   and its name in its quality colour, as in the profession window's recipe form;
-- - each reagent in a slot like the profession window's, "have/need Name" (grey when you have too few),
--   then the units owned (valued at what they'd sell for) and the units bought, from which source
--   (Vendor, AH, Craft), and what that costs. Hover an icon for the item; Shift-click links it.
-- - Sell: the vendor and AH exits for the batch, the AH's parts (price, cut, deposit, sale chance),
--   the listings behind the price (walls flagged) and your own;
-- - Result: where to sell, profit, ROI, value added, confidence, and the best batch (the reagents or the
--   market sets it);
-- - Mr. Market, when a price is well away from its fair value; then the verdict.
-- A vendor craft (the Vendor crafts view) counts vendor prices only and shows what your materials would
-- fetch raw on the AH; an AH flip gets its own layout (buy, sell, result, verdict).
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
local ICON_SIZE = 47            -- the result's round icon, as on the profession window's recipe form
local ICON_INSET = 8            -- room for its quality ring, which reaches past the button
local NAME_WIDTH = WIDTH - ICON_INSET - ICON_SIZE - 10
local SLOT_SIZE, SLOT_GAP = 36, 4   -- a reagent's slot (the profession window's is 39)
local QUESTION_MARK = 134400
local GOLD, GREEN, ORANGE, RED, BLUE, GREY = "|cffffd100", "|cff33ff33", "|cffff9933", "|cffff5533", "|cff66ccff", "|cff999999"
local SOURCE_COLOR = { vendor = GOLD, ah = BLUE, craft = "|cffff88ff" }
local SOURCE_TEXT = { vendor = "Vendor", ah = "AH", craft = "Craft" }
local SOURCE_FROM = { vendor = "from a vendor", ah = "from the AH", craft = "crafted" }
local GRADE_COLOR = { A = GREEN, B = "|cffb4ff33", C = GOLD, D = RED }

local panel, scroll, child, current, header
local lines, rows, slots = {}, {}, {}
local usedLines, usedRows, usedSlots, height, nextGap, last = 0, 0, 0, 0, 0, nil

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

-- ---------------------------------------------------------------- icons

local function ItemName(itemID)
    return C_Item.GetItemNameByID(itemID) or ("item " .. itemID)
end

-- The name in its quality colour, without the brackets of a link.
local function QualityName(itemID)
    local quality = C_Item.GetItemQualityByID(itemID)
    local color = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    return color and (color.hex .. ItemName(itemID) .. "|r") or ItemName(itemID)
end

-- Hovering an icon shows the item (then self.tip's lines); a modified click acts as on any item button
-- (Shift: link it in chat, Ctrl: try it on, Alt+Right: into the tray, Bags.lua).
local function ItemEnter(self)
    if not self.itemID then return end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetItemByID(self.itemID)
    if self.tip and #self.tip > 0 then
        GameTooltip:AddLine(" ")
        for _, text in ipairs(self.tip) do GameTooltip:AddLine(text, 1, 1, 1, true) end
    end
    GameTooltip:Show()
end

local function ItemClick(self)
    local _, link = C_Item.GetItemInfo(self.itemID or 0)
    if link then HandleModifiedItemClick(link) end
end

-- The result at the top, as the profession window's recipe form shows it: a round icon (Blizzard's
-- CircularGiantItemButtonTemplate, the Auction House's quality ring) with the count, the name in its
-- quality colour, and short lines under the name.
local function Header(itemID, count, subLines)
    if not header then
        header = CreateFrame("Frame", nil, child)
        header:SetWidth(WIDTH)
        local icon = CreateFrame("Button", nil, header, "CircularGiantItemButtonTemplate")
        icon:SetSize(ICON_SIZE, ICON_SIZE)
        icon:SetPoint("TOPLEFT", ICON_INSET, -ICON_INSET)
        icon:SetScript("OnEnter", ItemEnter)
        icon:SetScript("OnLeave", GameTooltip_Hide)
        icon:SetScript("OnClick", ItemClick)
        header.icon = icon
        header.name = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightMed2")
        header.name:SetPoint("TOPLEFT", icon, "TOPRIGHT", 10, -2)
        header.name:SetWidth(NAME_WIDTH)
        header.name:SetJustifyH("LEFT")
        header.name:SetMaxLines(2)
        header.lines = {}
    end
    local icon = header.icon
    icon.itemID = itemID
    icon.Icon:SetTexture(C_Item.GetItemIconByID(itemID) or QUESTION_MARK)
    icon:SetItemButtonQuality(C_Item.GetItemQualityByID(itemID))
    icon.Count:SetText(tostring(count))
    icon.Count:SetShown(count > 1)
    header.name:SetText(QualityName(itemID))
    local prev, textHeight = header.name, header.name:GetStringHeight()
    for i, text in ipairs(subLines) do
        local fs = header.lines[i]
        if not fs then
            fs = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetJustifyH("LEFT")
            fs:SetWidth(NAME_WIDTH)
            header.lines[i] = fs
        end
        fs:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -3)
        fs:SetText(text)
        fs:Show()
        textHeight = textHeight + 3 + fs:GetStringHeight()
        prev = fs
    end
    for i = #subLines + 1, #header.lines do header.lines[i]:Hide() end
    local h = math.max(ICON_SIZE + 2 * ICON_INSET, textHeight + ICON_INSET + 4)
    header:SetHeight(h)
    header:Show()
    Place(header, h)
end

-- Where a reagent's units come from: "2 owned (8s), 2 AH (10s)".
local function Sources(line)
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
    return table.concat(parts, ", ")
end

-- The same per unit, for the slot's tooltip.
local function SourceTips(line)
    local tip = {}
    if line.owned > 0 then
        tip[#tip + 1] = string.format(L["%d of yours: %s each"], line.owned, Money.Format(line.ownedCost / line.owned))
    end
    if line.rest > 0 then
        tip[#tip + 1] = line.source and string.format(L["%d %s: %s each"], line.rest, L[SOURCE_FROM[line.source]],
            Money.Format(line.buyCost / line.rest)) or string.format(L["%d with no price yet"], line.rest)
    end
    return tip
end

-- White when you have enough, the profession window's grey when not.
local function NameColor(enough)
    local color = enough and HIGHLIGHT_FONT_COLOR or DISABLED_REAGENT_COLOR
    if color then return color:GetRGB() end
    if enough then return 1, 1, 1 end
    return 0.6, 0.6, 0.6
end

-- One reagent as the profession window shows it: a slot (Blizzard's slot art and quality frame) and
-- "have/need Name"; under the name, where the units come from. have: what you carry and bank.
local function Slot(line, have)
    usedSlots = usedSlots + 1
    local row = slots[usedSlots]
    if not row then
        row = CreateFrame("Button", nil, child)
        row:SetSize(WIDTH, SLOT_SIZE)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAtlas("Professions-Slot-bg")
        row.bg:SetSize(SLOT_SIZE, SLOT_SIZE)
        row.bg:SetPoint("LEFT")
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetAllPoints(row.bg)
        row.border = row:CreateTexture(nil, "OVERLAY")
        row.border:SetPoint("TOPLEFT", row.icon, "TOPLEFT")
        row.border:SetPoint("BOTTOMRIGHT", row.icon, "BOTTOMRIGHT", 1, -1)
        local glow = row:CreateTexture(nil, "HIGHLIGHT")
        glow:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
        glow:SetBlendMode("ADD")
        glow:SetAllPoints(row.icon)
        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.name:SetPoint("TOPLEFT", row.bg, "TOPRIGHT", 6, -3)
        row.name:SetPoint("RIGHT")
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false)
        row.detail = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.detail:SetPoint("BOTTOMLEFT", row.bg, "BOTTOMRIGHT", 6, 3)
        row.detail:SetPoint("RIGHT")
        row.detail:SetJustifyH("LEFT")
        row.detail:SetWordWrap(false)
        row:SetScript("OnEnter", ItemEnter)
        row:SetScript("OnLeave", GameTooltip_Hide)
        row:SetScript("OnClick", ItemClick)
        slots[usedSlots] = row
    end
    local itemID = line.itemID
    row.itemID, row.tip = itemID, SourceTips(line)
    row.icon:SetTexture(C_Item.GetItemIconByID(itemID) or QUESTION_MARK)
    local frames = PROFESSIONS_ITEM_QUALITY_ICON_BORDER_ATLASES
    local atlas = frames and frames[C_Item.GetItemQualityByID(itemID) or -1]
    if atlas then row.border:SetAtlas(atlas, false) end
    row.border:SetShown(atlas ~= nil)
    row.name:SetText(string.format("%d/%d %s", have, line.need, ItemName(itemID)))
    row.name:SetTextColor(NameColor(have >= line.need))
    row.detail:SetText(Sources(line))
    row:Show()
    Place(row, SLOT_SIZE, SLOT_GAP)
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
    elseif why.reason == "stale" then
        return string.format(L["%s: the cheapest price hasn't moved in %d days and the quantity never fell, so there's no sign of sales (D until you sell some)."],
            link, info.stale or 0)
    end
    return string.format(L["No %s listed now."], link)
end

local function Crafts(n)
    return n == 1 and L["1 craft"] or string.format(L["%d crafts"], n)
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
    local cut, measured, sales, fixed = ns.Ledger.Cut()
    Row(L["Cut"], ns.Ledger.CutText(cut, measured), {
        fixed and L["As set in the settings (measuring is off)."]
            or measured and string.format(L["Measured from %d of your sales."], sales)
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

-- The listings behind the AH price (your own left out); orange when every listing is at one price, or
-- when the cheapest price has held for days while the quantity never fell (a wall nobody buys from).
local function Listed(r)
    local itemID = r.recipe.output
    local row, age = ns.PriceDB.Get(itemID)
    if not row then return end
    local ladder = ns.PriceDB.UnpackLadder(row.ladder)
    local _, days = ns.PriceDB.History(row)
    local lo, hi = ladder[1] or row.min, ladder[#ladder - 1] or row.min
    local prices = lo == hi and Money.Compact(lo) or string.format(L["%s to %s"], Money.Compact(lo), Money.Compact(hi))
    local wall = #ladder == 2 and (row.n or 0) >= WALL
    local info = r.ctx and r.ctx.priceInfo[itemID]
    local stale = info and (info.sold or 0) == 0 and (info.stale or 0) >= ns.Econ.STALE_DAYS and info.stale or nil
    local tip = { string.format(L["%s listed at %s, not counting yours; %d day(s) of data; the last scan was %s ago."],
        BreakUpLargeNumbers(row.q or 0), prices, days, ns.FormatAge(age)) }
    if wall then tip[#tip + 1] = ORANGE .. L["Every listing is at one price: perhaps a single seller, so demand is unproven."] .. "|r" end
    if stale then
        tip[#tip + 1] = ORANGE .. string.format(L["The cheapest price has held at %s for %d days and the quantity never fell: no sign anyone buys at that price. Confidence D until you sell some."],
            Money.Compact(lo), stale) .. "|r"
    end
    local flag = wall or stale
    Row(L["Listed"], (flag and ORANGE or "") .. string.format(L["%s at %s"], BreakUpLargeNumbers(row.q or 0), prices)
        .. (flag and "|r" or ""), tip)
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

-- A vendor craft (the Vendor crafts view): what your own reagents would fetch on the AH instead.
local function RawOnAH(r)
    if (r.rawAH or 0) <= 0 then return end
    local bought = 0
    for _, line in ipairs(r.lines) do bought = bought + line.buyCost end
    Row(L["Raw on AH"], (r.rawBetter and ORANGE or "") .. Money.Compact(r.rawAH) .. (r.rawBetter and "|r" or ""), {
        L["What the reagents you own would fetch on the AH, after the cut and the deposits expected to be lost."],
        string.format(L["Crafting pays %s for them at a vendor."], Money.Format(r.best - bought)),
        r.rawBetter and (ORANGE .. L["Selling them on the AH pays more, though less surely."] .. "|r") or nil,
    })
end

local function Sell(r)
    local recipe = r.recipe
    Heading(L["Sell"])
    Row(L["Vendor"], r.vendorExit and Money.Compact(r.vendorExit) or (GREY .. L["won't buy"] .. "|r"), {
        r.vendorExit and string.format(L["What a vendor pays for the batch (%s each): certain and instant."],
            Money.Format(r.vendorExit / r.units)) or L["A vendor won't buy it."],
    })
    if r.view == "vendor" then
        Row(L["AH"], GREY .. L["not counted"] .. "|r", { L["Vendor crafts count vendor prices only: certain profit, no AH risk."] })
        RawOnAH(r)
    elseif recipe.bop then
        Row(L["AH"], GREY .. L["binds on pickup"] .. "|r", { L["It binds when picked up, so it can't be sold on the AH."] })
    elseif r.ahExit then
        local value = r.ahExit > 0 and Money.Compact(r.ahExit) or (ORANGE .. L["none"] .. "|r")
        Row(L["AH"], value, {
            string.format(L["What the batch nets: (price - cut - expected deposit loss) x %d, %s each."], r.units,
                Money.Format(r.ahUnit)),
            r.ahExit == 0 and (ORANGE .. L["The deposits it would likely lose outweigh its price."] .. "|r") or nil,
        })
        AHParts(r)
        Listed(r)
    else
        Row(L["AH"], GREY .. L["no price"] .. "|r", { L["Scan at the Auction House."] })
    end
    Yours(recipe.output)
end

-- ---------------------------------------------------------------- Result and verdict

-- Batch size (Evaluator.BatchAdvice, worked out once per result): the smaller of what the reagents
-- support (the most profit) and what the market takes (a quarter of what's listed), and which one set
-- it. Orange when this batch is bigger, green when it could be bigger.
local LIMIT_TEXT = { reagents = "reagents", market = "market" }

local function BatchRow(r)
    if not r.ctx then return end
    r.batch = r.batch or ns.Evaluator.BatchAdvice(r.recipe, r.crafts, r.ctx)
    local a = r.batch
    if not a.size then return end
    local tip = {}
    if a.best >= ns.Evaluator.BATCH_LIMIT then
        tip[#tip + 1] = string.format(L["Reagents: profit still grows at %d crafts."], a.best)
    elseif a.best == a.searched then
        tip[#tip + 1] = string.format(L["Reagents: only enough can be had for %s."], Crafts(a.best))
    else
        tip[#tip + 1] = string.format(L["Reagents: the most profit at %s (%s); past that each craft costs more than it earns."],
            Crafts(a.best), Money.Format(a.profit))
    end
    if a.cap then
        local info = r.ctx.priceInfo[r.recipe.output]
        tip[#tip + 1] = string.format(L["Market: a quarter of the %s listed is %s; selling more at once risks flooding it."],
            BreakUpLargeNumbers(info and info.listed or 0), Crafts(a.cap))
    end
    local color = ""
    if r.crafts > a.size then
        color = ORANGE
        tip[#tip + 1] = string.format(L["This batch is %s: make fewer."], Crafts(r.crafts))
    elseif r.crafts < a.size then
        color = GREEN
        tip[#tip + 1] = string.format(L["This batch is %s: you could make more."], Crafts(r.crafts))
    end
    local value = a.limit == "none" and L["no limit"]
        or string.format("%s (%s)", Crafts(a.size), L[LIMIT_TEXT[a.limit]])
    Row(L["Best batch"], color .. value .. (color ~= "" and "|r" or ""), tip)
end

-- Mr. Market (wowf-economics strategy-ideas.md): an AH price well away from its fair value, for the
-- reagents bought there and the result sold there. Hints only; nothing shows without 5 days of data.
local function MrMarket(r)
    local today, window = ns.PriceDB.Today(), ns.db.settings.historyDays
    local moods = {}
    local function consider(itemID, selling)
        local row = ns.PriceDB.Get(itemID)
        if not row then return end
        local z, share, fair = ns.Econ.MrMarket((ns.PriceDB.History(row)), today, row.mv, window)
        local mood = z and ns.Econ.Mood(z, share)
        if not mood then return end
        local good = (mood == "cheap") ~= selling   -- cheap is good when buying, dear when selling
        local advice
        if selling then
            advice = mood == "dear" and L["A good day to sell."] or L["Cheap today: hold if you can."]
        else
            advice = mood == "cheap" and L["A good day to buy."] or L["Dear today: buy later if you can."]
        end
        moods[#moods + 1] = {
            itemID = itemID,
            value = (good and GREEN or ORANGE) .. string.format("%s%d%% %s", share < 0 and "-" or "+",
                math.floor(math.abs(share) * 100 + 0.5), mood == "cheap" and L["cheap"] or L["dear"]) .. "|r",
            tip = { string.format(L["Today %s against a fair value of %s over %d days: %.1f standard deviations %s."],
                Money.Format(row.mv), Money.Format(fair), window, math.abs(z), z < 0 and L["below"] or L["above"]), advice },
        }
    end
    for _, line in ipairs(r.lines) do
        if line.source == "ah" then consider(line.itemID, false) end
    end
    if r.bestSource == "ah" then consider(r.recipe.output, true) end
    if #moods == 0 then return end
    Heading(L["Mr. Market"])
    for _, m in ipairs(moods) do
        Row(C_Item.GetItemNameByID(m.itemID) or ("item " .. m.itemID), m.value, m.tip)
    end
end

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
    BatchRow(r)
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

-- ---------------------------------------------------------------- an AH flip

local function FlipDetails(r)
    Header(r.recipe.output, r.units, { GREY .. L["Buy on the AH, sell to a vendor."] .. "|r" })

    Heading(L["Buy"])
    local prices = (r.lo and r.hi and r.lo ~= r.hi) and string.format(L["%s to %s"], Money.Compact(r.lo), Money.Compact(r.hi))
        or Money.Compact(r.lo or 0)
    Row(L["Listed"], string.format(L["%d at %s"], r.units, prices), {
        string.format(L["%d listed below what a vendor pays, at %s each, in your last full scan."], r.units, prices),
    })
    Row(L["Cost"], Money.Compact(r.cogs), { L["What buying all of them costs."] })

    Heading(L["Sell"])
    Row(L["Vendor"], Money.Compact(r.best), {
        string.format(L["What a vendor pays: %s each, certain and instant."], Money.Format(r.best / r.units)),
    })

    Heading(L["Result"])
    Row(L["Profit"], GREEN .. Money.Compact(r.profit) .. "|r", { L["The vendor's price minus what the listings cost."] })
    Row(L["ROI"], r.roi and Pct(r.roi) or L["n/a"], { L["Profit / cost."] })
    Row(L["Confidence"], (GRADE_COLOR[r.grade] or "") .. r.grade .. "|r", {
        string.format(L["Your last full scan is %s old, and listings vanish fast: A under 15 min, B under 1 h, C under 6 h."],
            ns.FormatAge(r.age)),
    })

    Heading(L["Verdict"])
    if r.recommended then
        Add(GREEN .. string.format(L["Recommended: buy %d (up to %s each), sell to a vendor."], r.units,
            Money.Compact(r.hi or 0)) .. "|r")
    else
        local why = {}
        for _, key in ipairs(r.reasons) do why[#why + 1] = ns.Evaluator.ReasonText(key) end
        Add(ORANGE .. L["Not recommended:"] .. "|r " .. table.concat(why, ", ") .. ".")
    end
    Add(GREY .. L["Buy them in Blizzard's Auction House: BuffettForever doesn't buy for you."] .. "|r")
end

-- ---------------------------------------------------------------- a recipe

local function RecipeDetails(r)
    local recipe = r.recipe
    local status = {}
    if r.known then
        status[#status + 1] = BLUE .. L["you know it"] .. "|r"
    elseif ns.RecipeIndex.IsKnown(recipe.recipeID, "any") then
        status[#status + 1] = L["one of your characters knows it"]
    else
        status[#status + 1] = L["not known"]
    end
    if recipe.new then
        status[#status + 1] = ns.RecipeIndex.IsConfirmed(recipe.recipeID) and L["new since Classic"]
            or (ORANGE .. L["new, unconfirmed"] .. "|r")
    end
    if r.crafts > 1 then status[#status + 1] = Crafts(r.crafts) end
    local about = {
        string.format("%s (%d/%d)", ns.RecipeIndex.ProfessionName(recipe.profession), recipe.yellow, recipe.grey),
        table.concat(status, ", "),
    }
    if r.vendorOnly then about[#about + 1] = GOLD .. L["Made entirely from goods a vendor sells."] .. "|r" end
    Header(recipe.output, r.units, about)

    Heading(L["Reagents"])
    local owned = r.ctx and r.ctx.owned
    for _, line in ipairs(r.lines) do Slot(line, owned and owned[line.itemID] or line.owned) end
    Row(L["Cost"], r.complete and Money.Compact(r.cogs) or "?", {
        r.view == "vendor" and L["Reagents you own count at what a vendor pays for them; the rest come from a vendor."]
            or L["Reagents you own count at what they'd sell for; the rest come from the cheapest of a vendor, the AH or a recipe you know."],
    })

    Sell(r)
    Result(r)
    MrMarket(r)
    Verdict(r)
end

-- ---------------------------------------------------------------- refresh

function DetailPanel.Refresh()
    if not panel then return end
    for i = 1, usedLines do lines[i]:Hide() end
    for i = 1, usedRows do rows[i]:Hide() end
    for i = 1, usedSlots do slots[i]:Hide() end
    if header then header:Hide() end
    usedLines, usedRows, usedSlots, height, nextGap, last = 0, 0, 0, 0, 0, nil
    local r = current
    panel.Text:SetShown(r == nil)
    scroll:SetShown(r ~= nil)
    if not r then return end
    if r.flip then FlipDetails(r) else RecipeDetails(r) end
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
