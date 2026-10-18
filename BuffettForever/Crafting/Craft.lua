local addonName, ns = ...

-- Crafting from BuffettForever (Justin, 2026-10-18: "craft the item from a button in the details section").
-- CraftRecipe needs the profession window open on the recipe's profession: closed, it does nothing at all
-- [F-135]. So the bar's Craft button (UI/CraftRow.lua) reads Open until it is, and that click opens it at
-- the recipe (OpenRecipe, as Blizzard's recipe tracker does); the next click crafts n (CraftRecipe, as the
-- window's Create does), inside the click. Reagents come from the bags (ReagentsFromBankAllowed is false
-- on Forever). States: ready, opening, crafting; Buy, Craft and Post exclude each other.
-- Every finished craft of a recipe in the data, from any window (UNIT_SPELLCAST_SUCCEEDED: the spell ID is
-- the recipe's), takes its reagents off the tray (they were used) and counts its result as made by you,
-- charDB.made[itemID] = { q, t }, which Post lists (Pricing/Post.lua).
-- /bf crafttest probes the calls, typed, so each runs inside a key press:
--   /bf crafttest <recipeID> [n]         the facts, then CraftRecipe(recipeID, n) (n = 0: the facts only)
--   /bf crafttest open <recipeID>        C_TradeSkillUI.OpenRecipe
--   /bf crafttest openline <skillLine>   C_TradeSkillUI.OpenTradeSkill
--   /bf crafttest stop                   C_TradeSkillUI.StopRecipeRepeat, during a batch
-- Probes and the bar's crafts log every craft and spellcast event of yours into diag.crafts (the last 10).
-- The profession window's own events are Crafting/Harvest.lua's; they come here as TRADESKILL_CHANGED.

local L = ns.L
local Craft = {}
ns.Craft = Craft
local events = ns.events

local KEEP = 10           -- probes and crafts kept in diag.crafts, and finished crafts in diag.counted
local BAGS_CHECK = 2      -- seconds after a craft ends to count the bags (the last result lands after the event)
local WATCH = 20          -- seconds a probe logs events
local WINDOW_CHECK = 2    -- seconds after an open, the window's state
local OPEN_TIMEOUT = 5    -- seconds for the profession window to open
local FIRST_CAST = 3      -- seconds for a batch's first cast to start
local CAST_GAP = 10       -- seconds with no cast event before a batch counts as over
local MADE_DAYS = 14      -- what you crafted counts as yours to post this long
local MADE_SETTLE = 2     -- seconds after a craft before the bags may lower what you made

local state = "ready"     -- ready, opening, crafting
local craft               -- the bar's open craft
local probe               -- the open probe
local watchTimer, craftTimer, openTimer
local blocked             -- why crafting from here is off this session (Forever blocked it)
local seenCasts = {}      -- castGUIDs counted already (a repeated event counts once)
local secretSkips = 0     -- finished casts skipped because their spell ID was a secret
local madeAt = {}         -- [itemID] = GetTime() of the last craft of it, this session

local function Show(v)
    if ns.IsSecret(v) then return "secret" end
    return tostring(v)
end

-- A step in a record (a probe or the bar's craft), timed from its start.
local function Log(rec, text)
    if not rec then return end
    rec.steps[#rec.steps + 1] = string.format("%.1fs %s", (debugprofilestop() - rec.started) / 1000, text)
end

local function Step(text)
    Log(probe, text)
    Log(craft, text)
end

local function Changed()
    ns.Fire("CRAFT_CHANGED", state)
end

-- ---------------------------------------------------------------- pure helpers (the self-test runs them)

-- How many crafts the counts allow (count(itemID) -> units you have), and the reagent that limits them.
function Craft.Craftable(reagents, count)
    local best, limit
    for _, r in ipairs(reagents) do
        local n = math.floor(count(r.itemID) / r.count)
        if not best or n < best then best, limit = n, r.itemID end
    end
    return best or 0, limit
end

-- The first reason the bar's Craft can't craft, from facts (Gather): unknown, combat, busy, casting,
-- reagents, requirement, window (then it opens the window), blocked, disabled, cooldown; nil when it can.
-- Blizzard's own order where it checks the same things (the window's ValidateControls).
function Craft.Blocker(f)
    if not f.known then return "unknown" end
    if f.combat then return "combat" end
    if f.busy then return "busy" end
    if f.casting then return "casting" end
    if f.craftable < 1 then return "reagents" end
    if f.requirement then return "requirement" end
    if not f.window then return "window" end
    if f.blocked then return "blocked" end
    if f.disabled then return "disabled" end
    if f.cooldown then return "cooldown" end
    return nil
end

-- Which recipe a finished cast was, if it counts: not a secret, not counted already (castGUID in seen), and a
-- recipe in the data. secret: the caller's issecretvalue of the spell ID.
function Craft.Counts(spellID, castGUID, seen, secret)
    if secret then return nil end
    if castGUID and seen[castGUID] then return nil end
    local recipe = ns.RecipeIndex.Get(spellID)
    if not recipe then return nil end
    if castGUID then seen[castGUID] = true end
    return recipe
end

-- What one craft of recipe uses and makes: { { itemID, count } }, the result's item and its units.
function Craft.Credits(recipe)
    local debits = {}
    for _, g in ipairs(recipe.reagents) do debits[#debits + 1] = { itemID = g.itemID, count = g.count } end
    return debits, recipe.output, math.max(1, recipe.count or 1)
end

-- ---------------------------------------------------------------- what you made (for Post)

local function MadeLedger()
    return ns.charDB and ns.charDB.made
end

local function CreditMade(itemID, units)
    local made = MadeLedger()
    if not made then return end
    local entry = made[itemID]
    if entry then
        entry.q, entry.t = entry.q + units, GetServerTime()
    else
        made[itemID] = { q = units, t = GetServerTime() }
    end
    madeAt[itemID] = GetTime()
end

-- Units of itemID you crafted that are still in your bags.
function Craft.Made(itemID)
    local entry = MadeLedger() and MadeLedger()[itemID]
    if not entry then return 0 end
    return math.min(entry.q, C_Item.GetItemCount(itemID) or 0)
end

-- What was posted (Pricing/Post.lua) is no longer yours to post.
function Craft.UseMade(itemID, units)
    local made = MadeLedger()
    local entry = made and made[itemID]
    if not entry then return end
    entry.q = entry.q - units
    if entry.q <= 0 then made[itemID] = nil end
end

-- The bags hold fewer than you made (sold, used, mailed): you made at most what's left. Not right after a
-- craft, while its result may still be on its way into the bags. Old entries go.
ns.On("BAGS_CHANGED", function()
    local made = MadeLedger()
    if not made then return end
    local now, clock = GetServerTime(), GetTime()
    for itemID, entry in pairs(made) do
        local bags = C_Item.GetItemCount(itemID) or 0
        if now - (entry.t or 0) > MADE_DAYS * 86400 then
            made[itemID] = nil
        elseif bags < entry.q and clock - (madeAt[itemID] or 0) > MADE_SETTLE then
            entry.q = bags
            if bags == 0 then made[itemID] = nil end
        end
    end
end)

-- ---------------------------------------------------------------- the window and the facts

local function WindowShown()
    return ProfessionsFrame ~= nil and ProfessionsFrame:IsShown() == true
end

-- Whether the profession window is open and ready on the recipe's profession (your own, not a link).
function Craft.WindowReady(recipe)
    local okReady, ready = pcall(C_TradeSkillUI.IsTradeSkillReady)
    if not okReady or ready ~= true then return false end
    local okBase, base = pcall(C_TradeSkillUI.GetBaseProfessionInfo)
    if not okBase or type(base) ~= "table" or ns.IsSecret(base.professionID) or base.professionID ~= recipe.profession then
        return false
    end
    for _, fn in ipairs({ C_TradeSkillUI.IsTradeSkillLinked, C_TradeSkillUI.IsTradeSkillGuild, C_TradeSkillUI.IsNPCCrafting }) do
        local ok, yes = pcall(fn)
        if ok and yes == true then return false end
    end
    return true
end

-- A requirement the game says isn't met (an anvil, a forge, a fire, a tool): its name, or nil. It answers
-- with the window closed [F-135].
local function Unmet(recipeID)
    local ok, requirements = pcall(C_TradeSkillUI.GetRecipeRequirements, recipeID)
    if not ok or type(requirements) ~= "table" then return nil end
    for _, q in ipairs(requirements) do
        if not ns.IsSecret(q.met) and q.met == false then return ns.SafeText(q.name, "?") end
    end
    return nil
end

-- The facts for Craft.Blocker about result r (r.recipe, r.known); the window's own answers only while it's
-- ready, since they're wrong before [F-123].
local function Gather(r)
    local recipe = r.recipe
    local f = { known = r.known == true, combat = ns.InCombat(), blocked = blocked ~= nil }
    f.busy = ns.Buy.IsBusy() or state == "crafting" or (ns.Post and ns.Post.IsBusy and ns.Post.IsBusy()) or false
    local _, _, _, _, _, isTradeskill = UnitCastingInfo("player")
    f.casting = isTradeskill ~= nil   -- wowf-ignore: SEC001 isTradeskill is NeverSecret in UnitCastingInfo's documentation
    f.craftable, f.limit = Craft.Craftable(recipe.reagents, ns.Tray.UsableCount)
    f.requirement = Unmet(recipe.recipeID)
    f.window = Craft.WindowReady(recipe)
    if f.window then
        local okInfo, info = pcall(C_TradeSkillUI.GetRecipeInfo, recipe.recipeID)
        if okInfo and type(info) == "table" then
            f.disabled = info.disabled == true or info.craftable == false
            f.disabledReason = ns.SafeText(info.disabledReason, nil)
            f.multiple = info.canCreateMultiple ~= false
        end
        local okCd, cooldown, _, charges = pcall(C_TradeSkillUI.GetRecipeCooldown, recipe.recipeID)
        if okCd and type(cooldown) == "number" and not ns.IsSecret(cooldown) and cooldown > 0 and (charges or 0) == 0 then
            f.cooldown = cooldown
        end
    end
    return f
end

-- How many the bar would craft: the Crafts box, at most what your bags make (1 when the recipe makes one at
-- a time).
local function Batch(r, f)
    if f.multiple == false then return 1 end
    return math.max(1, math.min(r.crafts or 1, f.craftable))
end

-- What the bar's Craft does for result r now: "craft", "open" or nil, its count, why not, and the facts.
function Craft.Plan(r)
    local f = Gather(r)
    local why = Craft.Blocker(f)
    if why == nil then return "craft", Batch(r, f), nil, f end
    if why == "window" then return state == "ready" and "open" or nil, Batch(r, f), why, f end
    return nil, Batch(r, f), why, f
end

-- Why Craft can't craft, for the player.
function Craft.WhyText(why, r, f)
    local recipe = r.recipe
    if why == "unknown" then return L["You don't know this recipe yet."] end
    if why == "combat" then return L["Not in combat."] end
    if why == "busy" then
        if state == "crafting" then return L["A craft is under way."] end
        return L["A purchase or a post is open."]
    end
    if why == "casting" then return L["You're casting: wait for it to finish."] end
    if why == "reagents" then
        local need
        for _, g in ipairs(recipe.reagents) do
            if g.itemID == f.limit then need = g.count end
        end
        local have = ns.Tray.UsableCount(f.limit)
        local text = string.format(L["Short of %s: %d in your bags, %d a craft."],
            C_Item.GetItemNameByID(f.limit) or ("item " .. f.limit), have, need or 1)
        local mail = ns.Collect.InMail(f.limit)
        if mail > 0 then text = text .. " " .. string.format(L["%d in your mailbox: collect them first."], mail) end
        return text
    end
    if why == "requirement" then return string.format(L["Needs %s."], f.requirement) end
    if why == "window" then
        return string.format(L["Crafting needs your %s window open: Open Profession opens it at this recipe."],
            ns.RecipeIndex.ProfessionName(recipe.profession))
    end
    if why == "blocked" then return L["Forever blocked crafting from an addon: use Create in the profession window."] end
    if why == "disabled" then return f.disabledReason or L["The profession window says it can't be made now."] end
    if why == "cooldown" then return string.format(L["On cooldown: %s."], ns.FormatAge(f.cooldown)) end
    return tostring(why)
end

function Craft.State()
    return state, craft
end

-- A craft is under way (Buy and Post wait for it).
function Craft.IsBusy()
    return state == "crafting"
end

-- ---------------------------------------------------------------- the bar's craft

local function StopCraftTimer()
    if craftTimer then
        craftTimer:Cancel()
        craftTimer = nil
    end
end

local function Keep(rec)
    if ns.db and not ns.readOnlyDB then
        local list = ns.db.diag.crafts or {}
        ns.db.diag.crafts = list
        table.insert(list, 1, rec)
        while #list > KEEP do table.remove(list) end
    end
end

local function Counts(recipeID)
    local r = ns.RecipeIndex.Get(recipeID)
    local out = {}
    if not r then return out end
    for _, reagent in ipairs(r.reagents) do out[reagent.itemID] = C_Item.GetItemCount(reagent.itemID) end
    out[r.output] = C_Item.GetItemCount(r.output)
    return out
end

local function CountsText(counts)
    local parts = {}
    for itemID, n in pairs(counts) do parts[#parts + 1] = string.format("%d x%d", itemID, n) end
    table.sort(parts)
    return table.concat(parts, ", ")
end

local function FinishCraft(outcome)
    local rec = craft
    if not rec then return end
    StopCraftTimer()
    Log(rec, "outcome " .. outcome)
    craft, state = nil, "ready"
    rec.outcome, rec.started = outcome, nil
    C_Timer.After(BAGS_CHECK, function() rec.bagsAfter = CountsText(Counts(rec.recipeID)) end)
    Keep(rec)
    local recipe = ns.RecipeIndex.Get(rec.recipeID)
    local name = recipe and ns.Items.Link(recipe.output) or tostring(rec.recipeID)
    if rec.done >= rec.n then
        ns.Print(string.format(L["Crafted %d %s."], rec.done * (recipe and math.max(1, recipe.count or 1) or 1), name))
        ns.ResultsList.ClearCrafts(rec.recipeID)   -- the box goes back to what the view's batch is now
    else
        local text = string.format(L["Crafting %s stopped after %d of %d."], name, rec.done, rec.n)
        if rec.error then text = text .. " " .. rec.error end
        ns.Print(text)
    end
    Changed()
end

-- No cast event for seconds: the batch is over (or never started, as when the window wasn't ready).
local function Watchdog(seconds)
    StopCraftTimer()
    craftTimer = C_Timer.NewTimer(seconds, function()
        craftTimer = nil
        if not craft then return end
        if craft.done == 0 and not craft.casting then craft.error = craft.error or L["Nothing happened: is the profession window open?"] end
        FinishCraft("no answer")
    end)
end

-- The bar's Open: the profession window at the recipe, inside the click.
function Craft.Open(r)
    if state ~= "ready" then return false end
    local ok, err = pcall(C_TradeSkillUI.OpenRecipe, r.recipe.recipeID)
    if not ok then
        ns.Print(string.format(L["The profession window wouldn't open (%s)."], tostring(err)))
        return false
    end
    state = "opening"
    if openTimer then openTimer:Cancel() end
    openTimer = C_Timer.NewTimer(OPEN_TIMEOUT, function()
        openTimer = nil
        if state == "opening" then
            state = "ready"
            Changed()
        end
    end)
    Changed()
    return true
end

-- The bar's Craft (result r at its Crafts box), inside the click: Open first when the window isn't ready.
function Craft.Start(r)
    local action, n, why, f = Craft.Plan(r)
    if action == "open" then return Craft.Open(r) end
    if action ~= "craft" then
        if why then ns.Print(Craft.WhyText(why, r, f)) end
        return false
    end
    local recipeID = r.recipe.recipeID
    craft = { t = GetServerTime(), build = select(2, GetBuildInfo()), kind = "button", recipeID = recipeID, n = n, done = 0,
              steps = {}, started = debugprofilestop() }
    craft.bagsBefore = CountsText(Counts(recipeID))
    state = "crafting"
    local ok, err = pcall(C_TradeSkillUI.CraftRecipe, recipeID, n)
    Log(craft, ok and string.format("CraftRecipe(%d, %d) called", recipeID, n) or ("CraftRecipe error: " .. tostring(err)))
    if not ok then
        craft.error = L["The game wouldn't craft it (logged)."]
        FinishCraft("craft error")
        return false
    end
    if craft then Watchdog(FIRST_CAST) end   -- an instant craft may have finished it already
    Changed()
    return true
end

-- The bar's Stop during a batch, inside the click: the cast under way finishes, the rest aren't made [F-135].
function Craft.Stop()
    if state ~= "crafting" or not craft then return end
    local ok, err = pcall(C_TradeSkillUI.StopRecipeRepeat)
    Log(craft, ok and "StopRecipeRepeat called" or ("StopRecipeRepeat error: " .. tostring(err)))
    craft.stopping = true
    if not craft.casting then FinishCraft("stopped") end
end

-- ---------------------------------------------------------------- events

-- Registered for "player" only (RegisterUnitEvent), so the unit isn't compared (it could be a secret).
local function Spell(event, castGUID, spellID)
    local secret = ns.IsSecret(spellID)
    if probe then
        local mark = (not secret and probe.recipeID and spellID == probe.recipeID) and " (the recipe)" or ""
        Log(probe, string.format("%s %s%s%s", event, Show(spellID), mark, ns.IsSecret(castGUID) and ", secret GUID" or ""))
    end
    local ours = craft and not secret and spellID == craft.recipeID
    if ours then Log(craft, event) end
    return ours
end

function events:UNIT_SPELLCAST_START(_, castGUID, spellID)
    if Spell("START", castGUID, spellID) then
        craft.casting = true
        Watchdog(CAST_GAP)
        Changed()
    end
end

function events:UNIT_SPELLCAST_SUCCEEDED(_, castGUID, spellID)
    local ours = Spell("SUCCEEDED", castGUID, spellID)
    local secret = ns.IsSecret(spellID)
    if secret and not ns.InCombat() then secretSkips = secretSkips + 1 end   -- out of combat it could have been a craft
    local recipe = Craft.Counts(spellID, not ns.IsSecret(castGUID) and castGUID or nil, seenCasts, secret)
    if recipe then
        local debits, output, units = Craft.Credits(recipe)
        ns.Tray.Debit(debits)
        CreditMade(output, units)
        -- Each counted craft, whichever window made it: the bar's button, or another (Blizzard's Create).
        if ns.db and not ns.readOnlyDB then
            local list = ns.db.diag.counted or {}
            ns.db.diag.counted = list
            local made = MadeLedger() and MadeLedger()[output]
            table.insert(list, 1, { t = GetServerTime(), recipeID = recipe.recipeID, by = ours and "button" or "other",
                                    made = made and made.q or 0, tray = #ns.Tray.Entries() })
            while #list > KEEP do table.remove(list) end
        end
    end
    if probe and not secret and spellID == probe.recipeID then
        local ok, left = pcall(C_TradeSkillUI.GetRemainingRecasts)
        Log(probe, string.format("  remaining recasts %s; bags %s", ok and Show(left) or "error", CountsText(Counts(probe.recipeID))))
    end
    if ours then
        craft.done, craft.casting = craft.done + 1, false
        if craft.done >= craft.n or craft.stopping then
            FinishCraft(craft.done >= craft.n and "crafted" or "stopped")
        else
            Watchdog(CAST_GAP)
            Changed()
        end
    end
end

local function Broke(event, castGUID, spellID)
    if Spell(event, castGUID, spellID) then
        craft.casting = false
        FinishCraft(string.lower(event))
    end
end

function events:UNIT_SPELLCAST_FAILED(_, castGUID, spellID) Broke("FAILED", castGUID, spellID) end
function events:UNIT_SPELLCAST_INTERRUPTED(_, castGUID, spellID) Broke("INTERRUPTED", castGUID, spellID) end
function events:UNIT_SPELLCAST_STOP(_, castGUID, spellID) Spell("STOP", castGUID, spellID) end

function events:TRADE_SKILL_CRAFT_BEGIN(recipeSpellID)
    Step("TRADE_SKILL_CRAFT_BEGIN " .. Show(recipeSpellID))
end

function events:TRADE_SKILL_ITEM_CRAFTED_RESULT(data)
    if not (probe or craft) then return end
    if type(data) ~= "table" then
        Step("TRADE_SKILL_ITEM_CRAFTED_RESULT " .. Show(data))
        return
    end
    Step(string.format("TRADE_SKILL_ITEM_CRAFTED_RESULT item %s x%s, GUID %s, operation %s", Show(data.itemID),
        Show(data.quantity), data.itemGUID ~= nil and "yes" or "no", Show(data.operationID)))
end

-- The batch stops being repeated (StopRecipeRepeat, moving): the cast under way may still finish [F-135].
function events:UPDATE_TRADESKILL_CAST_STOPPED(isScrapping)
    Step("UPDATE_TRADESKILL_CAST_STOPPED " .. Show(isScrapping))
    if not craft then return end
    craft.stopping = true
    if not craft.casting then FinishCraft("stopped") end
end

function events:OPEN_RECIPE_RESPONSE(recipeID, skillLineID, expansionSkillLineID)
    Step(string.format("OPEN_RECIPE_RESPONSE %s, line %s, %s", Show(recipeID), Show(skillLineID), Show(expansionSkillLineID)))
end

function events:UI_ERROR_MESSAGE(errorType, message)
    if not (probe or craft) then return end
    Step(string.format("UI_ERROR_MESSAGE %s: %s", Show(errorType), Show(message)))
    if craft and not ns.IsSecret(message) and type(message) == "string" then craft.error = message end
end

ns.On("TRADESKILL_CHANGED", function(event)
    Step(tostring(event) .. ", window shown " .. tostring(WindowShown()))
    if state == "opening" and event ~= "TRADE_SKILL_CLOSE" then
        local ok, ready = pcall(C_TradeSkillUI.IsTradeSkillReady)
        if ok and ready then
            if openTimer then
                openTimer:Cancel()
                openTimer = nil
            end
            state = "ready"
        end
    end
    Changed()
end)

ns.On("ACTION_BLOCKED", function(event, fn)
    if probe then
        Log(probe, string.format("%s %s", event, tostring(fn)))
        if not craft then
            ns.Print(L["Forever blocked the call (logged)."])
        end
    end
    if craft then
        blocked = tostring(fn)
        Log(craft, string.format("%s %s", event, tostring(fn)))
        craft.error = L["Forever blocked crafting from an addon: use Create in the profession window."]
        FinishCraft("blocked")
    end
end)

-- ---------------------------------------------------------------- /bf crafttest

-- What the game says about crafting a recipe right now (all read-only), for the probe.
local function Facts(recipeID)
    local f = { window = WindowShown(), bankAllowed = ns.Tray.BankUsable() }
    local r = ns.RecipeIndex.Get(recipeID)
    f.inData = r ~= nil
    local ok, value = pcall(C_TradeSkillUI.IsTradeSkillReady)
    f.ready = ok and Show(value) or "error"
    local okBase, base = pcall(C_TradeSkillUI.GetBaseProfessionInfo)
    if okBase and type(base) == "table" then
        f.base = string.format("%s %s %s/%s", Show(base.professionID), Show(base.professionName), Show(base.skillLevel),
            Show(base.maxSkillLevel))
    end
    local okLinked, linked = pcall(C_TradeSkillUI.IsTradeSkillLinked)
    local okGuild, guild = pcall(C_TradeSkillUI.IsTradeSkillGuild)
    local okNpc, npc = pcall(C_TradeSkillUI.IsNPCCrafting)
    f.linkedGuildNpc = string.format("%s %s %s", okLinked and Show(linked) or "error", okGuild and Show(guild) or "error",
        okNpc and Show(npc) or "error")
    local okCount, count = pcall(C_TradeSkillUI.GetCraftableCount, recipeID)
    f.craftableGame = okCount and Show(count) or "error"
    if r then
        f.craftableOurs = Craft.Craftable(r.reagents, ns.Tray.UsableCount)
        f.windowReady = Craft.WindowReady(r)
        local okProf, prof = pcall(C_TradeSkillUI.GetProfessionInfoBySkillLineID, r.profession)
        if okProf and type(prof) == "table" and prof.profession ~= nil then
            f.profession = Show(prof.profession)
            local okNear, near = pcall(C_TradeSkillUI.IsNearProfessionSpellFocus, prof.profession)
            f.nearFocus = okNear and Show(near) or "error"
        end
    end
    local okInfo, info = pcall(C_TradeSkillUI.GetRecipeInfo, recipeID)
    if okInfo and type(info) == "table" then
        f.info = string.format("learned %s, craftable %s, disabled %s (%s), canCreateMultiple %s", Show(info.learned),
            Show(info.craftable), Show(info.disabled), Show(info.disabledReason), Show(info.canCreateMultiple))
    else
        f.info = okInfo and "nil" or "error"
    end
    local okReq, requirements = pcall(C_TradeSkillUI.GetRecipeRequirements, recipeID)
    if okReq and type(requirements) == "table" then
        local parts = {}
        for _, q in ipairs(requirements) do
            parts[#parts + 1] = string.format("%s (type %s): %s", Show(q.name), Show(q.type), Show(q.met) == "true" and "met" or "not met")
        end
        f.requirements = #parts > 0 and table.concat(parts, "; ") or "none"
    else
        f.requirements = "error"
    end
    local okCd, cooldown, isDay, charges, maxCharges = pcall(C_TradeSkillUI.GetRecipeCooldown, recipeID)
    f.cooldown = okCd and string.format("%s (day %s, charges %s/%s)", Show(cooldown), Show(isDay), Show(charges), Show(maxCharges))
        or "error"
    local _, _, _, _, _, isTradeskill = UnitCastingInfo("player")
    -- wowf-ignore: SEC001 isTradeskill is NeverSecret in UnitCastingInfo's documentation
    f.casting = isTradeskill == nil and "no" or ("yes, tradeskill " .. tostring(isTradeskill))
    f.bags = CountsText(Counts(recipeID))
    return f
end

local function FinishProbe(outcome)
    local rec = probe
    if not rec then return end
    if watchTimer then
        watchTimer:Cancel()
        watchTimer = nil
    end
    Log(rec, "outcome " .. outcome)
    probe = nil
    rec.outcome, rec.started = outcome, nil
    if rec.recipeID then rec.bagsAfter = CountsText(Counts(rec.recipeID)) end
    Keep(rec)
    ns.Print(string.format(L["Craft test %s: %s, %d steps logged (/bf diag)."], rec.kind, outcome, #rec.steps))
end

local function Begin(kind, recipeID, n)
    if probe then FinishProbe("replaced by another test") end
    probe = { t = GetServerTime(), build = select(2, GetBuildInfo()), kind = kind, recipeID = recipeID, n = n,
              steps = {}, started = debugprofilestop() }
end

local function Watch()
    watchTimer = C_Timer.NewTimer(WATCH, function()
        watchTimer = nil
        FinishProbe(string.format("watched %d s", WATCH))
    end)
end

local function PrintFacts(f)
    ns.Print(string.format("craft test: window %s (ready on it %s), ready %s, base %s, linked/guild/NPC %s, bank reagents %s",
        tostring(f.window), tostring(f.windowReady), f.ready, tostring(f.base), f.linkedGuildNpc, tostring(f.bankAllowed)))
    ns.Print(string.format("craft test: craftable %s (ours %s), %s", f.craftableGame, tostring(f.craftableOurs), f.info))
    ns.Print(string.format("craft test: requires %s; near the station %s; cooldown %s; casting %s; bags %s", f.requirements,
        tostring(f.nearFocus), f.cooldown, f.casting, f.bags))
end

-- /bf crafttest <recipeID> [n] | open <recipeID> | openline <skillLine> | stop
function Craft.Probe(msg)
    local arg1, arg2 = string.match(msg or "", "^%s*%S+%s*(%S*)%s*(%S*)")
    arg1 = string.lower(arg1 or "")
    if arg1 == "stop" then
        if not (probe and probe.kind == "craft") then Begin("stop") end
        local ok, err = pcall(C_TradeSkillUI.StopRecipeRepeat)
        local okLeft, left = pcall(C_TradeSkillUI.GetRemainingRecasts)
        Log(probe, string.format("StopRecipeRepeat %s; remaining recasts %s", ok and "called" or ("error: " .. tostring(err)),
            okLeft and Show(left) or "error"))
        if probe.kind == "stop" then Watch() end
        return
    end
    if craft then
        ns.Print(L["A craft is under way."])
        return
    end
    if arg1 == "open" or arg1 == "openline" then
        local id = tonumber(arg2)
        if not id then
            ns.Print(L["Usage: /bf crafttest open <recipeID> | openline <skillLine>"])
            return
        end
        Begin(arg1, arg1 == "open" and id or nil)
        Log(probe, "window shown before: " .. tostring(WindowShown()))
        local ok, result
        if arg1 == "open" then
            ok, result = pcall(C_TradeSkillUI.OpenRecipe, id)
        else
            ok, result = pcall(C_TradeSkillUI.OpenTradeSkill, id)
        end
        Log(probe, string.format("%s(%d) %s", arg1 == "open" and "OpenRecipe" or "OpenTradeSkill", id,
            ok and ("returned " .. Show(result)) or ("error: " .. tostring(result))))
        C_Timer.After(WINDOW_CHECK, function()
            if probe then Log(probe, "window shown: " .. tostring(WindowShown())) end
        end)
        Watch()
        return
    end
    local id, n = tonumber(arg1), tonumber(arg2) or 1
    if not id or n < 0 then
        ns.Print(L["Usage: /bf crafttest <recipeID> [crafts] (0: facts only), open <recipeID>, openline <skillLine>, stop"])
        return
    end
    n = math.floor(n)
    Begin("craft", id, n)
    probe.facts = Facts(id)
    PrintFacts(probe.facts)
    if n == 0 then
        FinishProbe("facts only")
        return
    end
    local ok, err = pcall(C_TradeSkillUI.CraftRecipe, id, n)
    Log(probe, ok and string.format("CraftRecipe(%d, %d) called", id, n) or ("CraftRecipe error: " .. tostring(err)))
    Watch()
end

-- /bf diag: the last craft or probe, and what you made.
function Craft.PrintDiag()
    local rec = ns.db and ns.db.diag.crafts and ns.db.diag.crafts[1]
    if rec then
        ns.Print(string.format("craft %s %s %s x%s: %s%s; bags after %s; %s", date("%H:%M:%S", rec.t), rec.kind,
            tostring(rec.recipeID), tostring(rec.n), tostring(rec.outcome), rec.done and (", made " .. rec.done) or "",
            tostring(rec.bagsAfter), table.concat(rec.steps or {}, ", ")))
    end
    local parts = {}
    for itemID, entry in pairs(MadeLedger() or {}) do parts[#parts + 1] = string.format("%d x%d", itemID, entry.q) end
    if #parts > 0 then ns.Print("made, to post: " .. table.concat(parts, ", ")) end
    if secretSkips > 0 then ns.Print(string.format("crafts skipped (secret spell ID): %d", secretSkips)) end
    if blocked then ns.Print("crafting from here is off this session: " .. blocked) end
end

-- ---------------------------------------------------------------- self-test

function Craft.SelfTest(report)
    local passed, failed = 0, 0
    local function check(name, ok, detail)
        if ok then passed = passed + 1 else failed = failed + 1 end
        report(name, ok, detail)
    end
    local counts = { [2589] = 5, [2318] = 7, [4470] = 2 }
    local function count(itemID) return counts[itemID] or 0 end
    local a = Craft.Craftable({ { itemID = 2589, count = 1 } }, count)
    local b, limit = Craft.Craftable({ { itemID = 2318, count = 3 }, { itemID = 4470, count = 2 } }, count)
    local c = Craft.Craftable({ { itemID = 2589, count = 1 }, { itemID = 999, count = 1 } }, count)
    check("CRAFT-COUNT", a == 5 and b == 1 and limit == 4470 and c == 0,
        "5 Linen Cloth: 5 crafts; 7 Light Leather and 2 Simple Wood for 3 + 2: 1, limited by the wood; one missing: 0")

    local base = { known = true, craftable = 2, window = true }
    local function with(changes)
        local f = {}
        for k, v in pairs(base) do f[k] = v end
        for k, v in pairs(changes) do f[k] = v end
        return Craft.Blocker(f)
    end
    check("CRAFT-WHY", with({}) == nil and with({ known = false, combat = true }) == "unknown"
        and with({ combat = true, busy = true }) == "combat" and with({ busy = true, casting = true }) == "busy"
        and with({ craftable = 0, window = false }) == "reagents" and with({ requirement = "Anvil", window = false }) == "requirement"
        and with({ window = false, cooldown = 60 }) == "window" and with({ blocked = true, disabled = true }) == "blocked"
        and with({ disabled = true, cooldown = 60 }) == "disabled" and with({ cooldown = 60 }) == "cooldown",
        "unknown, combat, busy, casting, reagents, a requirement, the window, blocked, disabled, cooldown, in that order")

    local seen = {}
    local bandage = Craft.Counts(3275, "Cast-1", seen, false)
    local debits, output, units = Craft.Credits(bandage or { reagents = {}, output = 0, count = 0 })
    check("CRAFT-SPELL", bandage ~= nil and #debits == 1 and debits[1].itemID == 2589 and debits[1].count == 1 and output == 1251
        and units == 1 and Craft.Counts(3275, "Cast-1", seen, false) == nil and Craft.Counts(3273, "Cast-2", seen, false) == nil
        and Craft.Counts(3275, "Cast-3", seen, true) == nil,
        "Linen Bandage's spell takes 1 Linen Cloth and makes 1 bandage; the same cast twice, the First Aid spell and a secret: nothing")

    local B = ns.Evaluator.CraftableBatch
    check("BEST-BAGS", B(5, 3) == 3 and B(2, 9) == 2 and B(nil, 4) == 4 and B(5, 0) == 1,
        "the best batch within what your bags make (5 of 3: 3; 2 of 9: 2; no batch: all 4), at least 1")
    return passed, failed
end

for _, event in ipairs({ "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_FAILED",
    "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_STOP" }) do
    ns.eventFrame:RegisterUnitEvent(event, "player")
end
for _, event in ipairs({ "TRADE_SKILL_CRAFT_BEGIN", "TRADE_SKILL_ITEM_CRAFTED_RESULT", "UPDATE_TRADESKILL_CAST_STOPPED",
    "OPEN_RECIPE_RESPONSE", "UI_ERROR_MESSAGE" }) do
    ns.eventFrame:RegisterEvent(event)
end
