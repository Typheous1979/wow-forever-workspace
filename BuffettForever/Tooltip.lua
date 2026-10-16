local addonName, ns = ...

-- Price lines on item tooltips (TooltipDataProcessor; ui-patterns.md "Tooltips"):
--   AH market value and how old it is, AH min buyout, what a vendor pays (skipped when
--   Blizzard's tooltip already shows a sell price) and what a vendor charges once a merchant
--   selling the item has been visited. Prices are per unit. Comparison tooltips are skipped.
-- Blizzard calls tooltip:Show() after the post-calls, so there is no Show here.

local L = ns.L
local Money = ns.Money

local STALE = 48 * 3600                  -- older AH data is shown grey
local LABEL_R, LABEL_G, LABEL_B = 0.4, 0.8, 1   -- BuffettForever blue
local GREY = 0.55

local function BlizzardShowsSellPrice(data)
    if type(data.lines) ~= "table" then return false end
    for _, line in ipairs(data.lines) do
        if line.type == Enum.TooltipDataLineType.SellPrice and line.price then return true end
    end
    return false
end

local function AddPriceLines(tooltip, data)
    local itemID = data.id
    if type(itemID) ~= "number" or ns.IsSecret(itemID) then return end
    local row, age = ns.PriceDB.Get(itemID)
    if row then
        local r, g, b, vr, vg, vb = LABEL_R, LABEL_G, LABEL_B, 1, 1, 1
        if age > STALE then r, g, b, vr, vg, vb = GREY, GREY, GREY, GREY, GREY, GREY end
        tooltip:AddDoubleLine(string.format(L["AH market (%s ago)"], ns.FormatAge(age)), Money.Format(row.mv),
            r, g, b, vr, vg, vb)
        tooltip:AddDoubleLine(L["AH min buyout"], Money.Format(row.min), r, g, b, vr, vg, vb)
    end
    if not BlizzardShowsSellPrice(data) then
        local sell = select(11, C_Item.GetItemInfo(itemID))
        if type(sell) == "number" and sell > 0 then
            tooltip:AddDoubleLine(L["Vendor pays"], Money.Format(sell), LABEL_R, LABEL_G, LABEL_B, 1, 1, 1)
        end
    end
    local price, _, limited = ns.Merchant.Get(itemID)
    if price then
        local label = limited and L["Vendor sells it for (limited)"] or L["Vendor sells it for"]
        tooltip:AddDoubleLine(label, Money.Format(price), LABEL_R, LABEL_G, LABEL_B, 1, 1, 1)
    end
end

TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
    if not ns.db or not data or tooltip.isShopping then return end
    if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
    AddPriceLines(tooltip, data)
end)
