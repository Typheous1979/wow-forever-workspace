local addonName, ns = ...

-- Crafting from BuffettForever (Justin, 2026-10-18: "craft the item from a button in the details section").
-- First /bf crafttest, a probe of what no addon has done on Forever yet, typed so each call runs inside a
-- key press:
--   /bf crafttest <recipeID> [n]         the facts, then CraftRecipe(recipeID, n) (n = 0: the facts only)
--   /bf crafttest open <recipeID>        C_TradeSkillUI.OpenRecipe: can an addon open the profession window?
--   /bf crafttest openline <skillLine>   C_TradeSkillUI.OpenTradeSkill
--   /bf crafttest stop                   C_TradeSkillUI.StopRecipeRepeat, during a batch
-- Each one logs every craft and spellcast event of yours for 20 s into diag.crafts (the last 10): does it
-- craft with the window closed, which events come and in what order, is the spell ID the recipe's, is it
-- ever secret, where reagents come from (ReagentsFromBankAllowed), what the window's checks say with it
-- closed. The profession window's own events are Crafting/Harvest.lua's; they come here as
-- TRADESKILL_CHANGED.

local L = ns.L
local Craft = {}
ns.Craft = Craft
local events = ns.events

local KEEP = 10           -- probes kept in diag.crafts
local WATCH = 20          -- seconds a probe logs events
local WINDOW_CHECK = 2    -- seconds after an open, the window's state

local probe               -- the open probe
local watchTimer

-- A value for the log: never a secret's.
local function Show(v)
    if ns.IsSecret(v) then return "secret" end
    return tostring(v)
end

local function Step(text)
    if not probe then return end
    probe.steps[#probe.steps + 1] = string.format("%.1fs %s", (debugprofilestop() - probe.started) / 1000, text)
end

-- How many crafts the counts allow (count(itemID) -> units you have), and the reagent that limits them.
function Craft.Craftable(reagents, count)
    local best, limit
    for _, r in ipairs(reagents) do
        local n = math.floor(count(r.itemID) / r.count)
        if not best or n < best then best, limit = n, r.itemID end
    end
    return best or 0, limit
end

-- The bags' count of a recipe's reagents and its result.
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

local function WindowShown()
    return ProfessionsFrame ~= nil and ProfessionsFrame:IsShown() == true
end

-- What the game says about crafting a recipe right now (all read-only).
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

local function Finish(outcome)
    local rec = probe
    if not rec then return end
    if watchTimer then
        watchTimer:Cancel()
        watchTimer = nil
    end
    Step("outcome " .. outcome)
    probe = nil
    rec.outcome, rec.started = outcome, nil
    if rec.recipeID then rec.bagsAfter = CountsText(Counts(rec.recipeID)) end
    ns.eventFrame:UnregisterEvent("OPEN_RECIPE_RESPONSE")
    ns.eventFrame:UnregisterEvent("UI_ERROR_MESSAGE")
    if ns.db and not ns.readOnlyDB then
        local list = ns.db.diag.crafts or {}
        ns.db.diag.crafts = list
        table.insert(list, 1, rec)
        while #list > KEEP do table.remove(list) end
    end
    ns.Print(string.format(L["Craft test %s: %s, %d steps logged (/bf diag)."], rec.kind, outcome, #rec.steps))
end

local function Begin(kind, recipeID, n)
    if probe then Finish("replaced by another test") end
    probe = { t = GetServerTime(), build = select(2, GetBuildInfo()), kind = kind, recipeID = recipeID, n = n,
              steps = {}, started = debugprofilestop() }
    ns.eventFrame:RegisterEvent("OPEN_RECIPE_RESPONSE")
    ns.eventFrame:RegisterEvent("UI_ERROR_MESSAGE")
end

local function Watch()
    watchTimer = C_Timer.NewTimer(WATCH, function()
        watchTimer = nil
        Finish(string.format("watched %d s", WATCH))
    end)
end

local function PrintFacts(f)
    ns.Print(string.format("craft test: window %s, ready %s, base %s, linked/guild/NPC %s, bank reagents %s",
        tostring(f.window), f.ready, tostring(f.base), f.linkedGuildNpc, tostring(f.bankAllowed)))
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
        Step(string.format("StopRecipeRepeat %s; remaining recasts %s", ok and "called" or ("error: " .. tostring(err)),
            okLeft and Show(left) or "error"))
        if probe.kind == "stop" then Watch() end
        return
    end
    if arg1 == "open" or arg1 == "openline" then
        local id = tonumber(arg2)
        if not id then
            ns.Print(L["Usage: /bf crafttest open <recipeID> | openline <skillLine>"])
            return
        end
        Begin(arg1, arg1 == "open" and id or nil)
        Step("window shown before: " .. tostring(WindowShown()))
        local ok, result
        if arg1 == "open" then
            ok, result = pcall(C_TradeSkillUI.OpenRecipe, id)
        else
            ok, result = pcall(C_TradeSkillUI.OpenTradeSkill, id)
        end
        Step(string.format("%s(%d) %s", arg1 == "open" and "OpenRecipe" or "OpenTradeSkill", id,
            ok and ("returned " .. Show(result)) or ("error: " .. tostring(result))))
        C_Timer.After(WINDOW_CHECK, function()
            if probe then Step("window shown: " .. tostring(WindowShown())) end
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
        Finish("facts only")
        return
    end
    local ok, err = pcall(C_TradeSkillUI.CraftRecipe, id, n)
    Step(ok and string.format("CraftRecipe(%d, %d) called", id, n) or ("CraftRecipe error: " .. tostring(err)))
    Watch()
end

-- ---------------------------------------------------------------- what a probe logs

-- Registered for "player" only (RegisterUnitEvent), so the unit isn't compared (it could be a secret).
local function Spell(event, _, castGUID, spellID)
    if not probe then return end
    local secret = ns.IsSecret(spellID)
    local mark = ""
    if not secret and probe.recipeID and spellID == probe.recipeID then mark = " (the recipe)" end
    Step(string.format("%s %s%s%s", event, Show(spellID), mark, ns.IsSecret(castGUID) and ", secret GUID" or ""))
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        local ok, left = pcall(C_TradeSkillUI.GetRemainingRecasts)
        Step(string.format("  remaining recasts %s; bags %s", ok and Show(left) or "error",
            probe.recipeID and CountsText(Counts(probe.recipeID)) or "-"))
    end
end

function events:UNIT_SPELLCAST_START(unit, castGUID, spellID) Spell("START", unit, castGUID, spellID) end
function events:UNIT_SPELLCAST_SUCCEEDED(unit, castGUID, spellID) Spell("SUCCEEDED", unit, castGUID, spellID) end
function events:UNIT_SPELLCAST_FAILED(unit, castGUID, spellID) Spell("FAILED", unit, castGUID, spellID) end
function events:UNIT_SPELLCAST_INTERRUPTED(unit, castGUID, spellID) Spell("INTERRUPTED", unit, castGUID, spellID) end
function events:UNIT_SPELLCAST_STOP(unit, castGUID, spellID) Spell("STOP", unit, castGUID, spellID) end

function events:TRADE_SKILL_CRAFT_BEGIN(recipeSpellID)
    Step("TRADE_SKILL_CRAFT_BEGIN " .. Show(recipeSpellID))
end

function events:TRADE_SKILL_ITEM_CRAFTED_RESULT(data)
    if not probe then return end
    if type(data) ~= "table" then
        Step("TRADE_SKILL_ITEM_CRAFTED_RESULT " .. Show(data))
        return
    end
    Step(string.format("TRADE_SKILL_ITEM_CRAFTED_RESULT item %s x%s, GUID %s, operation %s", Show(data.itemID),
        Show(data.quantity), data.itemGUID ~= nil and "yes" or "no", Show(data.operationID)))
end

function events:UPDATE_TRADESKILL_CAST_STOPPED(isScrapping)
    Step("UPDATE_TRADESKILL_CAST_STOPPED " .. Show(isScrapping))
end

function events:OPEN_RECIPE_RESPONSE(recipeID, skillLineID, expansionSkillLineID)
    Step(string.format("OPEN_RECIPE_RESPONSE %s, line %s, %s", Show(recipeID), Show(skillLineID), Show(expansionSkillLineID)))
end

function events:UI_ERROR_MESSAGE(errorType, message)
    Step(string.format("UI_ERROR_MESSAGE %s: %s", Show(errorType), Show(message)))
end

ns.On("TRADESKILL_CHANGED", function(event)
    if probe then Step(tostring(event) .. ", window shown " .. tostring(WindowShown())) end
end)

ns.On("ACTION_BLOCKED", function(event, fn)
    if probe then
        Step(string.format("%s %s", event, tostring(fn)))
        Finish("blocked")
    end
end)

-- /bf diag: the last probe.
function Craft.PrintDiag()
    local rec = ns.db and ns.db.diag.crafts and ns.db.diag.crafts[1]
    if not rec then return end
    ns.Print(string.format("craft test %s %s %s x%s: %s; bags after %s; %s", date("%H:%M:%S", rec.t), rec.kind,
        tostring(rec.recipeID), tostring(rec.n), tostring(rec.outcome), tostring(rec.bagsAfter),
        table.concat(rec.steps or {}, ", ")))
end

for _, event in ipairs({ "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_FAILED",
    "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_STOP" }) do
    ns.eventFrame:RegisterUnitEvent(event, "player")
end
for _, event in ipairs({ "TRADE_SKILL_CRAFT_BEGIN", "TRADE_SKILL_ITEM_CRAFTED_RESULT", "UPDATE_TRADESKILL_CAST_STOPPED" }) do
    ns.eventFrame:RegisterEvent(event)
end
