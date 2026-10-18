local addonName, ns = ...

-- Which recipes each character knows (professions-and-vendors.md "Recording which recipes a
-- character knows"), kept account-wide in recipesKnown["First Surname"]:
-- - At login: C_SpellBook.IsSpellKnown for every recipe in Data/Recipes.lua replaces the
--   character's set, with no profession window needed (it agreed with "learned" on all 592
--   Leatherworking recipes [F-123]). A dropped profession drops its recipes.
-- - During the session: NEW_RECIPE_LEARNED adds one at once.
-- - The profession window (TRADE_SKILL_SHOW / LIST_UPDATE / DATA_SOURCE_CHANGED, debounced; the
--   player's own profession only, not a linked, guild or NPC window) adds its learned recipes and
--   fills diag.harvest[professionID]:
--   - which call lists the recipes and how many;
--   - learned recipes missing from the data;
--   - GetRecipeSchematic yields and reagents against the data;
--   - IsSpellKnown against "learned".
--   diag.harvest.closed probes the window-closed calls; diag.harvest.login describes the login read.
--   Being listed by the window isn't evidence a recipe exists on Forever: GetAllRecipeIDs lists the
--   whole skill line, Season-of-Discovery recipes included.
-- Also this character's professions and skill (Harvest.Professions, for the Profession profits view):
-- GetProfessions' slots read through GetProfessionInfo with no window open, as Forever's own professions
-- book does (undocumented, present at runtime [F-123]), plus the profession of any known recipe no slot
-- showed; and each known recipe's skill-up colour (Harvest.Difficulty). diag.harvest.professions keeps
-- the raw slots, Blizzard's difficulty against ours, and the view's evaluation time.

local L = ns.L
local Harvest = {}
ns.Harvest = Harvest
local events = ns.events

local DEBOUNCE = 0.5
local SAMPLE = 10             -- IDs kept in each diagnostics sample
local CLOSED_PROBE_DELAY = 1  -- seconds after TRADE_SKILL_CLOSE
local LOGIN_READ_DELAY = 5    -- seconds after login
local FLAG_NEW = 1
local PROFESSION, YELLOW, GREY, OUTPUT, COUNT, FIRST_REAGENT = 1, 3, 4, 6, 7, 8
local PROFESSION_SLOTS = 7    -- GetProfessions on Forever: 2 primary, then the secondary ones (any may be empty)
local DIFFICULTY_SAMPLE = 20  -- known recipes whose two difficulty readings diag keeps

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

-- At login: read this character's known recipes from the spellbook, for every recipe in the data.
-- Replaces the character's set; other characters' sets are kept.
local function ReadKnownRecipes()
    if not ns.db or ns.readOnlyDB then return end
    local key = ns.CharKey()
    if not key then return end
    local started = debugprofilestop()
    local known, checked, count = {}, 0, 0
    local bank = Enum.SpellBookSpellBank.Player
    for recipeID in pairs(ns.Recipes or {}) do
        checked = checked + 1
        if C_SpellBook.IsSpellKnown(recipeID, bank) then
            known[recipeID] = true
            count = count + 1
        end
    end
    local before = 0
    for _ in pairs(ns.db.recipesKnown[key] or {}) do before = before + 1 end
    ns.db.recipesKnown[key] = known
    HarvestDiag().login = { t = GetServerTime(), checked = checked, known = count, before = before,
                            ms = math.floor(debugprofilestop() - started) }
    if count ~= before then
        ns.Print(string.format(L["%d known recipes read for %s."], count, key))
    end
    ns.Fire("RECIPES_KNOWN_CHANGED")
end

ns.On("LOGIN", function()
    C_Timer.After(LOGIN_READ_DELAY, ReadKnownRecipes)
end)

-- Recipes known by this character (a set; empty until a profession window has been opened).
function Harvest.KnownByCharacter()
    local key = ns.CharKey()
    return key and ns.db and ns.db.recipesKnown[key] or {}
end

-- ---------------------------------------------------------------- professions and skill

local professions, professionKey   -- the list, cached until a profession or a rank changes
local difficulty = {}              -- [recipeID] = colour key or false, until the skill changes
local relative                     -- Enum.TradeskillRelativeDifficulty value -> colour key, built on first use
local colors                       -- colour key -> the profession window's colour, built on first use
local FALLBACK_COLOR = { optimal = "ffff8040", medium = "ffffff00", easy = "ff40bf40", trivial = "ff808080" }

-- The data's skill line for one the client reports: the line itself when the data has recipes on it,
-- else its parent's (Forever gives each profession a child line [F-126]); nil otherwise. isDataLine and
-- parentOf come in as functions, so the self-test runs on plain tables.
function Harvest.ProfessionLine(line, isDataLine, parentOf)
    if type(line) ~= "number" then return nil end
    if isDataLine(line) then return line end
    local parent = parentOf(line)
    if type(parent) == "number" and isDataLine(parent) then return parent end
    return nil
end

-- The slots' professions in order, then the lines of known recipes no slot showed (their rank unknown).
-- slots: { { line, name, rank, maxRank } }; knownLines: skill lines; nameOf(line) names the extra ones.
function Harvest.MergeProfessions(slots, knownLines, nameOf)
    local list, seen = {}, {}
    for _, s in ipairs(slots) do
        if s.line and not seen[s.line] then
            seen[s.line] = true
            list[#list + 1] = { skillLine = s.line, name = s.name, rank = s.rank, maxRank = s.maxRank }
        end
    end
    for _, line in ipairs(knownLines) do
        if not seen[line] then
            seen[line] = true
            list[#list + 1] = { skillLine = line, name = nameOf(line) }
        end
    end
    return list
end

local function IsDataLine(line)
    return ns.RecipeIndex.ProfessionLines()[line] ~= nil
end

local function ParentOf(line)
    local ok, info = pcall(C_TradeSkillUI.GetProfessionInfoBySkillLineID, line)
    return ok and type(info) == "table" and info.parentProfessionID or nil
end

-- The professions now, and the raw slots for diag.
local function ReadProfessions()
    local slots, raw = {}, {}
    local indexes = type(GetProfessions) == "function" and { GetProfessions() } or {}
    for i = 1, PROFESSION_SLOTS do
        local index = indexes[i]
        if index then
            local name, _, rank, maxRank, _, _, line = GetProfessionInfo(index)
            local dataLine = Harvest.ProfessionLine(line, IsDataLine, ParentOf)
            raw[#raw + 1] = { slot = i, name = name, rank = rank, maxRank = maxRank, line = line, dataLine = dataLine }
            if dataLine then slots[#slots + 1] = { line = dataLine, name = name, rank = rank, maxRank = maxRank } end
        end
    end
    local knownLines, seen = {}, {}
    for _, recipeID in ipairs(ns.RecipeIndex.Known()) do
        local line = ns.Recipes[recipeID][PROFESSION]
        if not seen[line] then
            seen[line] = true
            knownLines[#knownLines + 1] = line
        end
    end
    table.sort(knownLines)
    return Harvest.MergeProfessions(slots, knownLines, ns.RecipeIndex.ProfessionName), raw
end

local function Signature(list)
    local parts = {}
    for _, p in ipairs(list) do
        parts[#parts + 1] = string.format("%d:%s/%s", p.skillLine, tostring(p.rank), tostring(p.maxRank))
    end
    return table.concat(parts, ",")
end

-- A known recipe's colour key from Blizzard (GetRecipeInfo works with the window closed [F-123]), or nil.
local function BlizzardDifficulty(recipeID)
    if not relative then
        relative = {}
        local E = Enum.TradeskillRelativeDifficulty or {}
        for name, key in pairs({ Optimal = "optimal", Medium = "medium", Easy = "easy", Trivial = "trivial" }) do
            if E[name] then relative[E[name]] = key end
        end
    end
    local ok, info = pcall(C_TradeSkillUI.GetRecipeInfo, recipeID)
    if ok and type(info) == "table" and info.relativeDifficulty ~= nil then return relative[info.relativeDifficulty] end
    return nil
end

-- This character's professions with recipes in the data, in the order of Blizzard's professions window:
-- { { skillLine, name, rank, maxRank } }. The first read of a session also records the raw slots and,
-- for the known recipes, Blizzard's difficulty against the one from the thresholds.
function Harvest.Professions()
    if professions then return professions end
    local raw
    professions, raw = ReadProfessions()
    professionKey = Signature(professions)
    if ns.db and not ns.readOnlyDB then
        local old = HarvestDiag().professions
        -- window: whether the profession window was open for Blizzard's difficulty readings
        local d = { t = GetServerTime(), build = select(2, GetBuildInfo()), slots = raw, eval = old and old.eval,
                    difficulty = {}, window = ProfessionsFrame ~= nil and ProfessionsFrame:IsShown() or false }
        for _, recipeID in ipairs(ns.RecipeIndex.Known()) do
            if #d.difficulty >= DIFFICULTY_SAMPLE then break end
            local row = ns.Recipes[recipeID]
            local rank = Harvest.Rank(row[PROFESSION])
            d.difficulty[#d.difficulty + 1] = string.format("%d %s/%s at %s (%d/%d)", recipeID,
                tostring(BlizzardDifficulty(recipeID)), tostring(ns.RecipeIndex.Difficulty(rank, row[YELLOW], row[GREY])),
                tostring(rank), row[YELLOW], row[GREY])
        end
        HarvestDiag().professions = d
    end
    return professions
end

-- A profession's rank and max rank, or nil when no slot gave them.
function Harvest.Rank(skillLine)
    for _, p in ipairs(Harvest.Professions()) do
        if p.skillLine == skillLine then return p.rank, p.maxRank end
    end
    return nil
end

-- A known recipe's skill-up colour key ("optimal", "medium", "easy", "trivial"): Blizzard's own when it
-- gives one, else from your rank and the recipe's thresholds; nil for a recipe this character doesn't know
-- or a profession whose rank is unknown.
function Harvest.Difficulty(recipeID)
    local cached = difficulty[recipeID]
    if cached ~= nil then return cached or nil end
    local key
    if ns.RecipeIndex.IsKnown(recipeID, "char") then
        key = BlizzardDifficulty(recipeID)
        if not key then
            local row = ns.Recipes[recipeID]
            key = row and ns.RecipeIndex.Difficulty((Harvest.Rank(row[PROFESSION])), row[YELLOW], row[GREY])
        end
    end
    difficulty[recipeID] = key or false
    return key
end

-- The profession window's colour for a difficulty key, as |c markup.
function Harvest.DifficultyColor(key)
    if not colors then
        colors = { optimal = DIFFICULT_DIFFICULTY_COLOR, medium = FAIR_DIFFICULTY_COLOR, easy = EASY_DIFFICULTY_COLOR,
                   trivial = TRIVIAL_DIFFICULTY_COLOR }
    end
    local color = colors[key]
    if type(color) == "table" and color.GenerateHexColorMarkup then return color:GenerateHexColorMarkup() end
    return "|c" .. (FALLBACK_COLOR[key] or "ffffffff")
end

-- The Profession profits view's evaluation: how many recipes and how long (the latest and the slowest).
function Harvest.NoteEval(n, ms)
    if not ns.db or ns.readOnlyDB then return end
    local d = HarvestDiag().professions or {}
    HarvestDiag().professions = d
    local maxMs = math.max(d.eval and d.eval.maxMs or 0, ms)
    d.eval = { t = GetServerTime(), n = n, ms = math.floor(ms + 0.5), maxMs = math.floor(maxMs + 0.5) }
end

-- Skill-ups, a profession learned or dropped (weapon skill-ups too, which change nothing here): re-read,
-- and tell the list only when a profession or a rank changed.
function events:SKILL_LINES_CHANGED()
    if not professions then return end
    local list = ReadProfessions()
    local key = Signature(list)
    if key == professionKey then return end
    professions, professionKey = list, key
    wipe(difficulty)
    ns.Fire("PROFESSIONS_CHANGED")
end

ns.On("RECIPES_KNOWN_CHANGED", function()   -- a first recipe can bring a profession with it
    professions = nil
    wipe(difficulty)
end)

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
    if g and g.known then
        ns.Print(string.format("login: %d known recipes read from the spellbook (%d checked, %s before) in %d ms",
            g.known, g.checked, tostring(g.before), g.ms or 0))
    end
    local p = h.professions
    if p then
        local parts = {}
        for _, s in ipairs(p.slots or {}) do
            parts[#parts + 1] = string.format("%d %s %s/%s line %s -> %s", s.slot, tostring(s.name), tostring(s.rank),
                tostring(s.maxRank), tostring(s.line), tostring(s.dataLine))
        end
        ns.Print("professions: " .. (#parts > 0 and table.concat(parts, "; ") or "no slot"))
        if p.difficulty and #p.difficulty > 0 then
            ns.Print("skill-up (Blizzard/thresholds): " .. table.concat(p.difficulty, "; "))
        end
        if p.eval then
            ns.Print(string.format("Profession profits: %d recipes evaluated in %d ms (slowest %d ms)", p.eval.n, p.eval.ms,
                p.eval.maxMs or p.eval.ms))
        end
    end
end

-- /bf selftest: the skill-line mapping and the professions' order.
function Harvest.SelfTest(report)
    local data, parents = { [165] = true, [185] = true, [129] = true }, { [2937] = 165 }
    local function isData(line) return data[line] == true end
    local function parentOf(line) return parents[line] end
    local P = Harvest.ProfessionLine
    local mapped = P(165, isData, parentOf) == 165 and P(2937, isData, parentOf) == 165 and P(999, isData, parentOf) == nil
        and P(nil, isData, parentOf) == nil
    local list = Harvest.MergeProfessions({ { line = 165, name = "Leatherworking", rank = 49, maxRank = 75 } }, { 129, 165 },
        function(line) return "line " .. line end)
    local merged = #list == 2 and list[1].skillLine == 165 and list[1].rank == 49 and list[2].skillLine == 129
        and list[2].rank == nil and list[2].name == "line 129"
    local ok = mapped and merged
    report("PROF-MAP", ok, ok and "a client line maps to the data's (or its parent's); known recipes add the rest"
        or string.format("mapping %s, merging %s", tostring(mapped), tostring(merged)))
    return ok and 1 or 0, ok and 0 or 1
end

for _, event in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED",
    "TRADE_SKILL_CLOSE", "NEW_RECIPE_LEARNED", "SKILL_LINES_CHANGED" }) do
    ns.eventFrame:RegisterEvent(event)
end
