local addonName, ns = ...

-- Which recipes each character knows, read from the profession window (professions-and-vendors.md
-- "Recording which recipes a character knows"). On TRADE_SKILL_SHOW / LIST_UPDATE /
-- DATA_SOURCE_CHANGED (debounced), for the player's own profession only (not a linked, guild or
-- NPC window): every recipe the window lists goes into recipesSeen (it exists on Forever), every
-- learned one into recipesKnown[charKey]. NEW_RECIPE_LEARNED adds one at once.
-- The harvest also answers the open profession probes (CLAUDE.md) in diag.harvest[professionID]:
-- which call lists the recipes and how many; learned recipes missing from Data/Recipes.lua;
-- GetRecipeSchematic yields and reagents against the data; C_SpellBook.IsSpellKnown against
-- "learned"; and (diag.harvest.closed, .login) GetRecipeInfo / GetRecipeSchematic with the window
-- closed and IsSpellKnown at login.

local L = ns.L
local Harvest = {}
ns.Harvest = Harvest
local events = ns.events

local DEBOUNCE = 0.5
local SAMPLE = 10             -- IDs kept in each diagnostics sample
local CLOSED_PROBE_DELAY = 1  -- seconds after TRADE_SKILL_CLOSE
local LOGIN_PROBE_DELAY = 5   -- seconds after login
local LOGIN_PROBE_MAX = 50    -- known recipes checked with IsSpellKnown at login
local FLAG_NEW = 1
local OUTPUT, COUNT, FIRST_REAGENT = 6, 7, 8

local pending
local printed = {}            -- [professionID] = learned count already announced this session
local checkedSchematics = {}  -- [professionID] = true once the schematics were compared this session
local probeKnown              -- a learned recipe, for the closed-window probe

local function Sample(list, value)
    if #list < SAMPLE then list[#list + 1] = value end
end

local function HarvestDiag()
    ns.db.diag.harvest = ns.db.diag.harvest or {}
    return ns.db.diag.harvest
end

-- The recipe IDs the open window lists, the call that gave them, and the filtered count.
-- GetFilteredRecipeIDs follows the window's filters (Forever's filter menu: skill-up, have
-- materials, slots; "show unlearned" is forced off), so it can return a subset. Known recipes only
-- accumulate, so a filtered window adds fewer and removes none. GetAllRecipeIDs is preferred when
-- it works.
local function ListRecipes()
    local filtered = C_TradeSkillUI.GetFilteredRecipeIDs()
    local filteredCount = type(filtered) == "table" and #filtered or nil
    if type(C_TradeSkillUI.GetAllRecipeIDs) == "function" then   -- runtime-only, signature unverified
        local ok, all = pcall(C_TradeSkillUI.GetAllRecipeIDs)
        if ok and type(all) == "table" then return all, "GetAllRecipeIDs", filteredCount end
    end
    return type(filtered) == "table" and filtered or {}, "GetFilteredRecipeIDs", filteredCount
end

-- Our row against the client's schematic: yield, output and basic reagents. nil when they agree.
local function CompareSchematic(recipeID, row)
    local ok, s = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
    if not ok or type(s) ~= "table" then return "no schematic" end
    local problems = {}
    if s.quantityMin ~= row[COUNT] or s.quantityMax ~= row[COUNT] then
        problems[#problems + 1] = string.format("yield %s-%s, data %d", tostring(s.quantityMin), tostring(s.quantityMax), row[COUNT])
    end
    if s.outputItemID and s.outputItemID ~= row[OUTPUT] then
        problems[#problems + 1] = string.format("output %d, data %d", s.outputItemID, row[OUTPUT])
    end
    local want, got = {}, {}
    for i = FIRST_REAGENT, #row, 2 do want[row[i]] = row[i + 1] end
    for _, slot in ipairs(s.reagentSlotSchematics or {}) do
        local reagent = slot.reagents and slot.reagents[1]
        if slot.reagentType == Enum.CraftingReagentType.Basic and reagent and reagent.itemID then
            got[reagent.itemID] = (got[reagent.itemID] or 0) + (slot.quantityRequired or 0)
        end
    end
    for itemID, count in pairs(want) do
        if got[itemID] ~= count then
            problems[#problems + 1] = string.format("reagent %d x%s, data x%d", itemID, tostring(got[itemID]), count)
        end
    end
    for itemID, count in pairs(got) do
        if not want[itemID] then problems[#problems + 1] = string.format("extra reagent %d x%d", itemID, count) end
    end
    if #problems == 0 then return nil end
    return table.concat(problems, "; ")
end

local function Run()
    pending = nil
    if not ns.db or ns.readOnlyDB then return end
    if not C_TradeSkillUI.IsTradeSkillReady() then return end   -- LIST_UPDATE fires again when it is
    if C_TradeSkillUI.IsTradeSkillLinked() or C_TradeSkillUI.IsTradeSkillGuild() or C_TradeSkillUI.IsNPCCrafting() then
        return
    end
    local key = ns.CharKey()
    if not key then return end
    local prof = C_TradeSkillUI.GetBaseProfessionInfo() or {}
    local profID = prof.professionID or 0
    local ids, source, filteredCount = ListRecipes()
    local known = ns.db.recipesKnown[key] or {}
    ns.db.recipesKnown[key] = known
    local seen = ns.db.recipesSeen
    local recipes = ns.Recipes or {}
    local compare = not checkedSchematics[profID]
    local d = {
        t = GetServerTime(), build = select(2, GetBuildInfo()), dataBuild = ns.RecipesBuild,
        profession = prof.professionName, parentProfessionID = prof.parentProfessionID,
        skill = prof.skillLevel, maxSkill = prof.maxSkillLevel,
        source = source, listed = #ids, filtered = filteredCount, learned = 0, enchants = 0,
        newListed = 0, notInData = 0, notInDataSample = {},
        spellKnownAgree = 0, spellKnownDisagree = 0, disagreeSample = {},
    }
    if compare then
        d.schematicChecked, d.schematicMismatch, d.mismatchSample = 0, 0, {}
    else
        local previous = HarvestDiag()[profID]
        if previous then
            d.schematicChecked, d.schematicMismatch, d.mismatchSample =
                previous.schematicChecked, previous.schematicMismatch, previous.mismatchSample
        end
    end
    for _, recipeID in ipairs(ids) do
        local info = C_TradeSkillUI.GetRecipeInfo(recipeID)
        if info then
            seen[recipeID] = true
            local row = recipes[recipeID]
            if row and bit.band(row[5], FLAG_NEW) ~= 0 then d.newListed = d.newListed + 1 end
            local ok, spellKnown = pcall(C_SpellBook.IsSpellKnown, recipeID, Enum.SpellBookSpellBank.Player)
            if ok then
                if (spellKnown == true) == (info.learned == true) then
                    d.spellKnownAgree = d.spellKnownAgree + 1
                else
                    d.spellKnownDisagree = d.spellKnownDisagree + 1
                    Sample(d.disagreeSample, string.format("%d %s learned %s, IsSpellKnown %s", recipeID,
                        tostring(info.name), tostring(info.learned), tostring(spellKnown)))
                end
            end
            if info.learned then
                d.learned = d.learned + 1
                known[recipeID] = true
                probeKnown = probeKnown or recipeID
                if row then
                    if compare then
                        d.schematicChecked = d.schematicChecked + 1
                        local problem = CompareSchematic(recipeID, row)
                        if problem then
                            d.schematicMismatch = d.schematicMismatch + 1
                            Sample(d.mismatchSample, string.format("%d %s: %s", recipeID, tostring(info.name), problem))
                        end
                    end
                elseif info.isEnchantingRecipe then
                    d.enchants = d.enchants + 1      -- enchant-only recipes are left out on purpose
                else
                    d.notInData = d.notInData + 1
                    Sample(d.notInDataSample, string.format("%d %s", recipeID, tostring(info.name)))
                end
            end
        end
    end
    checkedSchematics[profID] = true
    HarvestDiag()[profID] = d
    if printed[profID] ~= d.learned then
        printed[profID] = d.learned
        ns.Print(string.format(L["%s: %d known recipes recorded for %s."], tostring(d.profession), d.learned, key))
    end
    ns.Fire("RECIPES_KNOWN_CHANGED")
end

local function Schedule()
    if not pending then pending = C_Timer.NewTimer(DEBOUNCE, Run) end
end

function events:TRADE_SKILL_SHOW()
    Schedule()
end

function events:TRADE_SKILL_LIST_UPDATE()
    Schedule()
end

function events:TRADE_SKILL_DATA_SOURCE_CHANGED()
    Schedule()
end

function events:NEW_RECIPE_LEARNED(recipeID)
    if not ns.db or ns.readOnlyDB or type(recipeID) ~= "number" then return end
    local key = ns.CharKey()
    if not key then return end
    ns.db.recipesKnown[key] = ns.db.recipesKnown[key] or {}
    ns.db.recipesKnown[key][recipeID] = true
    ns.db.recipesSeen[recipeID] = true
    ns.Fire("RECIPES_KNOWN_CHANGED")
end

-- Probe: do GetRecipeInfo / GetRecipeSchematic work once the window is closed, for a known recipe
-- and for one in our data that this character doesn't know?
function events:TRADE_SKILL_CLOSE()
    if pending then
        pending:Cancel()
        pending = nil
    end
    if not probeKnown or not ns.db or ns.readOnlyDB then return end
    C_Timer.After(CLOSED_PROBE_DELAY, function()
        local key = ns.CharKey()
        local known = key and ns.db.recipesKnown[key] or {}
        local unknown
        for recipeID in pairs(ns.Recipes or {}) do
            if not known[recipeID] then
                unknown = recipeID
                break
            end
        end
        local function probe(recipeID)
            if not recipeID then return nil end
            local okI, info = pcall(C_TradeSkillUI.GetRecipeInfo, recipeID)
            local okS, s = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
            local hasSchematic = okS and type(s) == "table"
            return {
                recipeID = recipeID, info = okI and info ~= nil, learned = okI and info and info.learned or nil,
                schematic = hasSchematic, reagentSlots = hasSchematic and #(s.reagentSlotSchematics or {}) or nil,
                yield = hasSchematic and s.quantityMin or nil, problem = (hasSchematic and ns.Recipes[recipeID])
                    and CompareSchematic(recipeID, ns.Recipes[recipeID]) or nil,
            }
        end
        HarvestDiag().closed = { t = GetServerTime(), known = probe(probeKnown), unknown = probe(unknown) }
    end)
end

-- Probe: at login, does C_SpellBook.IsSpellKnown confirm the recipes harvested earlier?
ns.On("LOGIN", function()
    C_Timer.After(LOGIN_PROBE_DELAY, function()
        if not ns.db or ns.readOnlyDB then return end
        local key = ns.CharKey()
        local known = key and ns.db.recipesKnown[key]
        if not known then return end
        local d = { t = GetServerTime(), checked = 0, agree = 0, disagree = 0, sample = {} }
        for recipeID in pairs(known) do
            if d.checked >= LOGIN_PROBE_MAX then break end
            local ok, spellKnown = pcall(C_SpellBook.IsSpellKnown, recipeID, Enum.SpellBookSpellBank.Player)
            d.checked = d.checked + 1
            if ok and spellKnown then
                d.agree = d.agree + 1
            else
                d.disagree = d.disagree + 1
                Sample(d.sample, recipeID)
            end
        end
        HarvestDiag().login = d
    end)
end)

-- Recipes known by this character (a set; empty until a profession window has been opened).
function Harvest.KnownByCharacter()
    local key = ns.CharKey()
    return key and ns.db and ns.db.recipesKnown[key] or {}
end

-- /bf diag: one line per harvested profession, plus the closed-window and login probes.
function Harvest.PrintDiag()
    local h = ns.db and ns.db.diag.harvest
    if not h then return end
    for profID, d in pairs(h) do
        if type(profID) == "number" then
            ns.Print(string.format(
                "harvest %s (%s, skill %s/%s): %d learned of %d listed by %s (filtered %s); %d new-ID listed; %d not in data, %d enchants; schematics %s checked, %s mismatched; IsSpellKnown agrees %d, disagrees %d",
                tostring(d.profession), tostring(profID), tostring(d.skill), tostring(d.maxSkill), d.learned, d.listed,
                tostring(d.source), tostring(d.filtered), d.newListed, d.notInData, d.enchants,
                tostring(d.schematicChecked), tostring(d.schematicMismatch), d.spellKnownAgree, d.spellKnownDisagree))
        end
    end
    local c = h.closed
    if c then
        local function show(p)
            if not p then return "-" end
            return string.format("%d info %s schematic %s slots %s yield %s%s", p.recipeID, tostring(p.info), tostring(p.schematic),
                tostring(p.reagentSlots), tostring(p.yield), p.problem and (" (" .. p.problem .. ")") or "")
        end
        ns.Print("window closed: known " .. show(c.known) .. "; unknown " .. show(c.unknown))
    end
    local g = h.login
    if g then
        ns.Print(string.format("login: IsSpellKnown confirmed %d of %d known recipes", g.agree, g.checked))
    end
end

for _, event in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED",
    "TRADE_SKILL_CLOSE", "NEW_RECIPE_LEARNED" }) do
    ns.eventFrame:RegisterEvent(event)
end
