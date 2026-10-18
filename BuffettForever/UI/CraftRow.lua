local addonName, ns = ...

-- The bar's second row under the details (Justin, 2026-10-18: a second row, each button doing one thing):
-- Craft. It crafts the shown recipe from your bags (Crafting/Craft.lua). CraftRecipe needs the profession
-- window open [F-135], so until it is the button reads Open, and that click opens the window at the recipe;
-- then Craft n, inside the click, n being the Crafts box within what your bags make. During a batch it's Stop
-- (the cast under way finishes). In every recipe view for recipes you know, and in Profession profits for
-- the rest too, greyed. Its tooltip gives the reagents' have/need in your bags and why it's greyed.

local L = ns.L
local UI = ns.UI
local CraftRow = {}
ns.CraftRow = CraftRow

local ROW_TOP = -52       -- under the bar's first row (UI/BuyBar.lua)
local GREEN, GREY, ORANGE = "|cff33ff33", "|cff999999", "|cffff9933"
local LABEL_R, LABEL_G, LABEL_B = 1, 0.82, 0

local row
local current, currentMode

local function Name(itemID)
    return C_Item.GetItemNameByID(itemID) or ("item " .. itemID)
end

local function Icon(itemID)
    local icon = itemID and C_Item.GetItemIconByID(itemID)
    return icon and string.format("|T%s:14:14|t ", icon) or ""
end

local function Shows(mode)
    return mode ~= nil and mode ~= "flip"
end

-- The status line: a batch under way (busy = true), or in the views with no buying, what Craft can do.
function CraftRow.Status(r, mode)
    local state, craft = ns.Craft.State()
    if state == "crafting" and craft then
        local recipe = ns.RecipeIndex.Get(craft.recipeID)
        local output = recipe and recipe.output
        local k = math.max(1, math.min(craft.n, craft.done + (craft.casting and 1 or 0)))
        return Icon(output) .. string.format(L["Crafting %s: %d of %d..."], output and Name(output) or tostring(craft.recipeID),
            k, craft.n), true
    end
    if not r or (mode ~= "tray" and mode ~= "vendor") then return nil, false end
    local action, n, why, f = ns.Craft.Plan(r)
    if action == "craft" then
        return GREEN .. string.format(n == 1 and L["Ready: %d craft from your bags."] or L["Ready: %d crafts from your bags."], n)
            .. "|r", false
    end
    if action == "open" or why == "window" then
        return GREY .. string.format(L["Your bags make %d: Open opens the profession window."], f.craftable) .. "|r", false
    end
    return ORANGE .. ns.Craft.WhyText(why, r, f) .. "|r", false
end

local function CraftTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    local r = current
    if ns.Craft.IsBusy() then
        GameTooltip:SetText(L["Stop"], 1, 1, 1)
        GameTooltip:AddLine(L["The craft under way finishes; the rest of the batch isn't made."], nil, nil, nil, true)
        GameTooltip:Show()
        return
    end
    local action, n, why, f = ns.Craft.Plan(r)
    GameTooltip:SetText(action == "open" and L["Open"] or L["Craft"], 1, 1, 1)
    GameTooltip:AddDoubleLine(L["Crafts"], tostring(n), LABEL_R, LABEL_G, LABEL_B, 1, 1, 1)
    for _, g in ipairs(r.recipe.reagents) do
        local have, need = ns.Tray.UsableCount(g.itemID), g.count * n
        local enough = have >= need
        GameTooltip:AddDoubleLine(Name(g.itemID), string.format("%d/%d", have, need), 1, 1, 1, 1, enough and 1 or 0.33,
            enough and 1 or 0.2)
        local mail = ns.Collect.InMail(g.itemID)
        if mail > 0 then GameTooltip:AddDoubleLine(" ", string.format(L["%d in the mailbox"], mail), 1, 1, 1, 0.6, 0.6, 0.6) end
    end
    local fromTray = 0
    for _, g in ipairs(r.recipe.reagents) do
        local _, entry = ns.Tray.Find(g.itemID)
        if entry then fromTray = fromTray + math.min(entry.qty, g.count * n) end
    end
    if fromTray > 0 then GameTooltip:AddDoubleLine(L["Off the tray"], tostring(fromTray), LABEL_R, LABEL_G, LABEL_B, 1, 1, 1) end
    GameTooltip:AddLine(" ")
    if action == "craft" then
        GameTooltip:AddLine(string.format(n == 1 and L["Crafts %d from your bags, in this click."]
            or L["Crafts %d from your bags, in this click: the batch runs on by itself."], n), 1, 1, 1, true)
    elseif action == "open" then
        GameTooltip:AddLine(ns.Craft.WhyText(why, r, f), 1, 1, 1, true)
        GameTooltip:AddLine(L["Then Craft makes them. The game crafts only with the profession's window open."], 0.6, 0.6, 0.6, true)
    elseif why then
        GameTooltip:AddLine(ns.Craft.WhyText(why, r, f), 1, 0.33, 0.2, true)
    end
    GameTooltip:AddLine(L["Crafting from the bags only. Each finished craft takes its reagents off the tray, in either window."],
        0.6, 0.6, 0.6, true)
    GameTooltip:Show()
end

function CraftRow.Refresh(r, mode)
    current, currentMode = r, mode
    if not row then return end
    local shows = Shows(mode) and r ~= nil
    row.Craft:SetShown(shows)
    if not shows then return end
    local state = ns.Craft.State()
    if state == "crafting" then
        row.Craft:SetText(L["Stop"])
        row.Craft:SetEnabled(true)
    elseif state == "opening" then
        row.Craft:SetText(L["Opening..."])
        row.Craft:SetEnabled(false)
    else
        local action, n = ns.Craft.Plan(r)
        if action == "open" then
            row.Craft:SetText(L["Open"])
        else
            row.Craft:SetText(string.format(L["Craft %d"], n))
        end
        row.Craft:SetEnabled(action ~= nil)
    end
    if GameTooltip:GetOwner() == row.Craft then CraftTooltip(row.Craft) end
end

local function OnCraft()
    if ns.Craft.IsBusy() then
        ns.Craft.Stop()
        return
    end
    if current and Shows(currentMode) then ns.Craft.Start(current) end
end

local function Build()
    local bar = ns.BuyBar.Frame()
    if row or not bar then return end
    row = {}
    row.Craft = UI.Button(bar, L["Craft"], 120, OnCraft)
    row.Craft:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, ROW_TOP)
    row.Craft:SetPoint("TOPRIGHT", bar, "TOPRIGHT", 0, ROW_TOP)
    row.Craft:SetMotionScriptsWhileDisabled(true)   -- the tooltip says why it's greyed
    row.Craft:SetScript("OnEnter", CraftTooltip)
    row.Craft:SetScript("OnLeave", GameTooltip_Hide)
    row.Craft:Hide()
end

-- After the Buy bar's own MAIN_BUILT (this file loads after UI/BuyBar.lua).
ns.On("MAIN_BUILT", Build)

-- A craft moved on, the profession window opened or closed, the bags or combat changed.
for _, message in ipairs({ "CRAFT_CHANGED", "TRADESKILL_CHANGED", "BAGS_CHANGED", "COMBAT_STARTED", "COMBAT_ENDED" }) do
    ns.On(message, function() ns.BuyBar.Refresh() end)
end
