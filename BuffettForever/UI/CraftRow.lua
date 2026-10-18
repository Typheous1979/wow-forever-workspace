local addonName, ns = ...

-- The bar's second row under the details (Justin, 2026-10-18: a second row, each button doing one thing):
-- [Create n] [Post n].
-- - Create crafts the shown recipe from your bags (Crafting/Craft.lua). CraftRecipe needs the profession window
--   open [F-135], so until it is the button reads Open Profession, and that click opens the window at the recipe;
--   then Create n (Justin's labels), inside the click, n being the Crafts box within what your bags make. During
--   a batch it's Stop (the cast under way finishes); during a post, Cancel.
-- - Sell on AH n (Justin's label) lists what you crafted that's still in your bags at the price the Options set,
--   the cheapest listing by others by default (Pricing/Post.lua): it looks the price up, Confirm posts it,
--   Confirm again answers the Auction House's warning. Not in Vendor crafts (those sell to a vendor), where
--   Create takes the whole row.
-- In every recipe view for recipes you know, and in Profession profits for the rest too, greyed. The tooltips
-- give the numbers as rows and say why a button is greyed.

local L = ns.L
local UI = ns.UI
local Money = ns.Money
local CraftRow = {}
ns.CraftRow = CraftRow

local ROW_TOP = -52       -- under the bar's first row (UI/BuyBar.lua)
local GAP = 6             -- between Create and Post
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

local function PostShows(mode)
    return Shows(mode) and mode ~= "vendor"
end

-- The status line: a post or a batch under way (busy = true), or in the views with no buying, what Create can do.
function CraftRow.Status(r, mode)
    local postText = ns.Post.StatusText()
    if postText then return postText, true end
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
        return GREY .. string.format(L["Your bags make %d: Open Profession opens its window."], f.craftable) .. "|r", false
    end
    return ORANGE .. ns.Craft.WhyText(why, r, f) .. "|r", false
end

-- ---------------------------------------------------------------- tooltips

local function CreateTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    local r = current
    if ns.Craft.IsBusy() then
        GameTooltip:SetText(L["Stop"], 1, 1, 1)
        GameTooltip:AddLine(L["The craft under way finishes; the rest of the batch isn't made."], nil, nil, nil, true)
        GameTooltip:Show()
        return
    end
    if ns.Post.IsBusy() then
        GameTooltip:SetText(L["Cancel"], 1, 1, 1)
        GameTooltip:AddLine(L["Drops the price shown: nothing is posted."], nil, nil, nil, true)
        GameTooltip:Show()
        return
    end
    local action, n, why, f = ns.Craft.Plan(r)
    GameTooltip:SetText(action == "open" and L["Open Profession"] or L["Create"], 1, 1, 1)
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
        GameTooltip:AddLine(string.format(n == 1 and L["Creates %d from your bags, in this click."]
            or L["Creates %d from your bags, in this click: the batch runs on by itself."], n), 1, 1, 1, true)
    elseif action == "open" then
        GameTooltip:AddLine(ns.Craft.WhyText(why, r, f), 1, 1, 1, true)
        GameTooltip:AddLine(L["Then Create makes them: the game crafts only with the profession's window open."], 0.6, 0.6, 0.6, true)
    elseif why then
        GameTooltip:AddLine(ns.Craft.WhyText(why, r, f), 1, 0.33, 0.2, true)
    end
    GameTooltip:AddLine(L["Crafting uses your bags only. Each finished craft takes its reagents off the tray, in either window."],
        0.6, 0.6, 0.6, true)
    GameTooltip:Show()
end

local function Row(label, value, r, g, b)
    GameTooltip:AddDoubleLine(label, value, LABEL_R, LABEL_G, LABEL_B, r or 1, g or 1, b or 1)
end

local function PostTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    local r = current
    local state, p = ns.Post.State()
    local cut = ns.Post.Cut()
    if p and (state == "planned" or state == "warned" or state == "posting") then
        GameTooltip:SetText(state == "planned" and L["Confirm the post"] or state == "warned" and L["Confirm again"] or L["Posting..."],
            1, 1, 1)
        Row(L["Price each"], Money.Format(p.price))
        if p.cheapest and p.cheapest ~= p.price then Row(L["The cheapest listing"], Money.Format(p.cheapest)) end
        Row(L["Units"], tostring(p.qty))
        Row(L["Total"], Money.Format(p.price * p.qty))
        Row(L["House cut"], ns.Ledger.CutText(cut))
        Row(L["If all sell"], Money.Format(ns.Post.Net(p.price, p.qty, cut)), 0.2, 1, 0.2)
        Row(L["Deposit"], string.format("%s (%s)", Money.Format(p.deposit), p.facts.durationName))
        if (p.vendorSell or 0) > 0 then Row(L["A vendor pays"], Money.Format(p.vendorSell * p.qty)) end
        if p.mv then Row(L["Market value"], Money.Format(p.mv)) end
        GameTooltip:AddLine(" ")
        local _, ruleText = ns.Post.Rule()
        GameTooltip:AddLine(string.format(L["The price is %s by others, from a search just now (Options set it). The deposit comes back if it sells and is lost if it expires."],
            p.kind == "bar" and ruleText or L["the cheapest listing"]), 0.6, 0.6, 0.6, true)
        if p.check == "vendor" then GameTooltip:AddLine(L["A vendor pays more than this brings after the cut."], 1, 0.33, 0.2, true) end
        if p.check == "low" then GameTooltip:AddLine(L["That's under half its market value: someone may be listing it cheap."], 1, 0.6, 0.2, true) end
        if state == "warned" then
            local warning = _G["CONFIRM_AUCTION_POSTING_TEXT"]
            if type(warning) == "string" then GameTooltip:AddLine(warning, 1, 0.82, 0, true) end
            GameTooltip:AddLine(L["Blizzard's own popup can't post this one: close it, and Confirm again here."], 0.6, 0.6, 0.6, true)
        end
        GameTooltip:Show()
        return
    end
    GameTooltip:SetText(L["Sell on AH"], 1, 1, 1)
    local _, ruleText = ns.Post.Rule()
    GameTooltip:AddLine(string.format(L["Lists what you crafted at %s by others: it looks the price up, then Confirm posts it."], ruleText),
        nil, nil, nil, true)
    if r then
        local ok, why, n = ns.Post.CanStart(r)
        Row(L["Crafted, in your bags"], tostring(n))
        local refused = ns.Post.LastWhy(r.recipe.output)
        if refused then GameTooltip:AddLine(refused, 1, 0.33, 0.2, true) end
        if not ok and why then GameTooltip:AddLine(why, 1, 0.33, 0.2, true) end
    end
    GameTooltip:Show()
end

-- ---------------------------------------------------------------- refresh

-- Create alone takes the row; with Post, each takes half.
local function Place(withPost)
    if row.withPost == withPost then return end
    row.withPost = withPost
    row.Create:ClearAllPoints()
    row.Create:SetPoint("TOPLEFT", row.bar, "TOPLEFT", 0, ROW_TOP)
    if withPost then
        row.Create:SetPoint("TOPRIGHT", row.bar, "TOP", -GAP / 2, ROW_TOP)
    else
        row.Create:SetPoint("TOPRIGHT", row.bar, "TOPRIGHT", 0, ROW_TOP)
    end
end

local function RefreshCreate(r)
    local craftState = ns.Craft.State()
    local postState = ns.Post.State()
    if craftState == "crafting" then
        row.Create:SetText(L["Stop"])
        row.Create:SetEnabled(true)
    elseif postState ~= "ready" then
        row.Create:SetText(L["Cancel"])
        row.Create:SetEnabled(postState ~= "posting")
    elseif craftState == "opening" then
        row.Create:SetText(L["Opening..."])
        row.Create:SetEnabled(false)
    else
        local action, n = ns.Craft.Plan(r)
        row.Create:SetText(action == "open" and L["Open Profession"] or string.format(L["Create %d"], n))
        row.Create:SetEnabled(action ~= nil)
    end
end

local function RefreshPost(r)
    local state = ns.Post.State()
    if state == "pricing" then
        row.Post:SetText(L["Checking..."])
        row.Post:SetEnabled(false)
    elseif state == "planned" then
        row.Post:SetText(L["Confirm"])
        row.Post:SetEnabled(true)
    elseif state == "warned" then
        row.Post:SetText(L["Confirm again"])
        row.Post:SetEnabled(true)
    elseif state == "posting" then
        row.Post:SetText(L["Posting..."])
        row.Post:SetEnabled(false)
    else
        local ok, _, n = ns.Post.CanStart(r)
        row.Post:SetText(n > 0 and string.format(L["Sell on AH %d"], n) or L["Sell on AH"])
        row.Post:SetEnabled(ok)
    end
end

function CraftRow.Refresh(r, mode)
    current, currentMode = r, mode
    if not row then return end
    local shows = Shows(mode) and r ~= nil
    local withPost = shows and PostShows(mode)
    row.Create:SetShown(shows)
    row.Post:SetShown(withPost)
    if not shows then return end
    Place(withPost)
    RefreshCreate(r)
    if withPost then RefreshPost(r) end
    if GameTooltip:GetOwner() == row.Create then CreateTooltip(row.Create) end
    if GameTooltip:GetOwner() == row.Post then PostTooltip(row.Post) end
end

-- ---------------------------------------------------------------- clicks and build

-- Create, Stop during a batch, Cancel during a post: each inside the click.
local function OnCreate()
    if ns.Craft.IsBusy() then
        ns.Craft.Stop()
        return
    end
    if ns.Post.IsBusy() then
        ns.Post.Cancel()
        return
    end
    if current and Shows(currentMode) then ns.Craft.Start(current) end
end

-- Post, then Confirm (and Confirm again after a warning): each inside the click.
local function OnPost()
    local state = ns.Post.State()
    if state == "planned" or state == "warned" then
        ns.Post.Confirm()
        return
    end
    if state == "ready" and current and PostShows(currentMode) then ns.Post.Start(current) end
end

local function Build()
    local bar = ns.BuyBar.Frame()
    if row or not bar then return end
    row = { bar = bar }
    row.Create = UI.Button(bar, L["Create"], 120, OnCreate)
    row.Create:SetMotionScriptsWhileDisabled(true)   -- the tooltip says why it's greyed
    row.Create:SetScript("OnEnter", CreateTooltip)
    row.Create:SetScript("OnLeave", GameTooltip_Hide)
    row.Create:Hide()
    row.Post = UI.Button(bar, L["Sell on AH"], 120, OnPost)
    row.Post:SetPoint("TOPLEFT", bar, "TOP", GAP / 2, ROW_TOP)
    row.Post:SetPoint("TOPRIGHT", bar, "TOPRIGHT", 0, ROW_TOP)
    row.Post:SetMotionScriptsWhileDisabled(true)
    row.Post:SetScript("OnEnter", PostTooltip)
    row.Post:SetScript("OnLeave", GameTooltip_Hide)
    row.Post:Hide()
    Place(true)
end

-- After the Buy bar's own MAIN_BUILT (this file loads after UI/BuyBar.lua).
ns.On("MAIN_BUILT", Build)

-- A craft or a post moved on, the profession window opened or closed, the bags or combat changed.
for _, message in ipairs({ "CRAFT_CHANGED", "POST_CHANGED", "TRADESKILL_CHANGED", "BAGS_CHANGED", "COMBAT_STARTED",
    "COMBAT_ENDED", "AH_THROTTLE_READY" }) do
    ns.On(message, function() ns.BuyBar.Refresh() end)
end
