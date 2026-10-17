local addonName, ns = ...

-- Auction deposits (auction-house.md "Deposits and the house cut"). Forever charges per auction
-- max(1s, floor(vendor price x quantity / 20) x 1, 4 or 12) for 2, 8 or 24 hours [F-129]
-- (Econ.Deposit), so the evaluator computes any deposit from the vendor price, the units posted
-- together and the duration Blizzard's sell frame remembers (CVar auctionHouseDurationDropdown), or
-- the one the settings fix.
-- At the auctioneer this module asks the game for the deposits Blizzard's sell frame shows
-- (CalculateCommodityDeposit, CalculateItemDeposit) for the bag items and the tray's outputs at all
-- three durations, and compares them with the formula, so a new build that changes it shows up in
-- diag.deposits. It also learns which items are commodities (one auction for a whole batch) and
-- which are gear (one auction each):
--   BuffettForeverDB.deposits[itemID] = { k = "c" (commodity) or "i" (item), t = time checked }
-- Fires DEPOSITS_CHANGED when it learns something.

local L = ns.L
local Deposits = {}
ns.Deposits = Deposits

local DURATIONS = 3
local QTY = 100              -- commodities are checked at 100 units (and one sample at 1)
local OPEN_DELAY = 1         -- seconds after the AH opens
local CHANGE_DELAY = 0.5     -- after a tray change or a scan
local AWAY_DELAY = 5         -- after login: does the call answer away from the AH?
local KEEP = 10              -- mismatches and samples kept in diag.deposits
local DURATION_NAMES = { "AUCTION_DURATION_ONE", "AUCTION_DURATION_TWO", "AUCTION_DURATION_THREE" }

local checked = {}           -- [itemID] = true once checked during this AH visit
local pending

local function Diag()
    local diag = ns.db.diag
    diag.deposits = diag.deposits or {}
    local d = diag.deposits
    d.samples = d.samples or {}
    d.mismatches = d.mismatches or {}
    return d
end

-- The duration deposits are figured for (1, 2, 3 = 2, 8, 24 hours): the settings' choice
-- (depositDuration), else the one Blizzard's sell frame remembers, else 8 hours (2, when the CVar is
-- unreadable). settings: for the self test.
function Deposits.Duration(settings)
    settings = settings or (ns.db and ns.db.settings) or {}
    local fixed = settings.depositDuration
    if type(fixed) == "number" and fixed >= 1 and fixed <= DURATIONS then return math.floor(fixed) end
    local value = tonumber(C_CVar.GetCVar("auctionHouseDurationDropdown") or "")
    if value and value >= 1 and value <= DURATIONS then return math.floor(value) end
    return 2
end

-- Blizzard's name for a duration ("8 Hours" on Forever), or "duration 2".
function Deposits.DurationName(d)
    d = d or Deposits.Duration()
    local name = DURATION_NAMES[d] and _G[DURATION_NAMES[d]]
    if type(name) == "string" then return name end
    return string.format(L["duration %d"], d)
end

-- What a vendor pays, the price the deposit is a share of (0 when a vendor won't buy it).
function Deposits.VendorSell(itemID)
    local sell = ns.ItemSellPrice and ns.ItemSellPrice[itemID] or select(11, C_Item.GetItemInfo(itemID))
    return type(sell) == "number" and sell or 0
end

-- Whether a batch of the item goes up as one auction (a commodity) or one auction each (gear): as
-- seen at the AH, else stackable means commodity. Unknown counts as a commodity. Never nil.
function Deposits.IsCommodity(itemID)
    local entry = ns.db and ns.db.deposits[itemID]
    if entry and entry.k then return entry.k == "c" end
    local stack = C_Item.GetItemMaxStackSizeByID(itemID)
    if type(stack) == "number" then return stack > 1 end
    return true
end

-- The deposit per unit when selling qty of the item (default: one) at duration d (default: the sell
-- frame's), by Forever's formula.
function Deposits.PerUnit(itemID, qty, d)
    return ns.Econ.DepositPerUnit(Deposits.VendorSell(itemID), qty or 1, d or Deposits.Duration(),
        Deposits.IsCommodity(itemID))
end

local function Push(list, entry)
    if #list < KEEP then list[#list + 1] = entry end
end

-- Ask the game (deposit(d, qty)) at every duration and compare with the formula; remember the kind.
local function Check(itemID, kind, qty, deposit)
    local d, sell, game = Diag(), Deposits.VendorSell(itemID), {}
    for duration = 1, DURATIONS do
        local ok, value = pcall(deposit, duration, qty)
        if not ok or type(value) ~= "number" or ns.IsSecret(value) then return false end
        game[duration] = value
    end
    checked[itemID] = true
    ns.db.deposits[itemID] = { k = kind == "commodity" and "c" or "i", t = GetServerTime() }
    d.checks = (d.checks or 0) + DURATIONS
    for duration = 1, DURATIONS do
        local formula = ns.Econ.Deposit(sell, qty, duration)
        if math.abs(formula - game[duration]) > 0.5 then
            d.mismatched = (d.mismatched or 0) + 1
            Push(d.mismatches, { itemID = itemID, kind = kind, qty = qty, duration = duration, sell = sell,
                                 game = game[duration], formula = formula })
        end
    end
    local seen = false
    for _, s in ipairs(d.samples) do
        if s.itemID == itemID then seen = true end
    end
    if not seen then Push(d.samples, { itemID = itemID, kind = kind, qty = qty, sell = sell, game[1], game[2], game[3] }) end
    return true
end

local function CheckCommodity(itemID)
    local ok = Check(itemID, "commodity", QTY, function(duration, qty)
        return C_AuctionHouse.CalculateCommodityDeposit(itemID, duration, qty)
    end)
    local d = Diag()
    if ok and not d.single then
        -- one unit: the 1s minimum, or a share of the vendor price?
        local okOne, one = pcall(C_AuctionHouse.CalculateCommodityDeposit, itemID, 1, 1)
        d.single = { itemID = itemID, game = okOne and one or nil, formula = ns.Econ.Deposit(Deposits.VendorSell(itemID), 1, 1) }
    end
    return ok
end

-- A bag item (ItemLocation): checked as a commodity or as an item; true when the game answered.
function Deposits.CheckLocation(location)
    if not location or not C_Item.DoesItemExist(location) then return false end
    local itemID = C_Item.GetItemID(location)
    if not itemID or checked[itemID] then return false end
    local status = C_AuctionHouse.GetItemCommodityStatus(location)
    if status == Enum.ItemCommodityStatus.Commodity then return CheckCommodity(itemID) end
    if status == Enum.ItemCommodityStatus.Item then
        return Check(itemID, "item", 1, function(duration, qty)
            return C_AuctionHouse.CalculateItemDeposit(location, duration, qty)
        end)
    end
    return false
end

local function CheckBags()
    local count = 0
    for bag = Enum.BagIndex.Backpack, Enum.BagIndex.ReagentBag do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local itemID = C_Container.GetContainerItemID(bag, slot)
            if itemID and not checked[itemID] then
                local location = ItemLocation:CreateFromBagAndSlot(bag, slot)
                local ok, valid = pcall(C_AuctionHouse.IsSellItemValid, location, false)
                if ok and valid and Deposits.CheckLocation(location) then count = count + 1 end
            end
        end
    end
    return count
end

-- The tray's outputs: commodity or gear from the item-key info (not cached yet: the next run).
local function CheckTray()
    local ids = {}
    for _, entry in ipairs(ns.Tray.Entries()) do ids[#ids + 1] = entry.itemID end
    if #ids == 0 then return 0 end
    local count = 0
    for _, recipeID in ipairs(ns.RecipeIndex.UsingAny(ids, { confirmed = true })) do
        local output = ns.RecipeIndex.Get(recipeID).output
        if not checked[output] then
            local info = C_AuctionHouse.GetItemKeyInfo(C_AuctionHouse.MakeItemKey(output))
            if info and info.isCommodity then
                if CheckCommodity(output) then count = count + 1 end
            elseif info then
                checked[output] = true
                ns.db.deposits[output] = { k = "i", t = GetServerTime() }   -- gear: checked when one is in your bags
                count = count + 1
            end
        end
    end
    return count
end

local function Run()
    pending = nil
    if not ns.ahOpen or not ns.db or ns.readOnlyDB then return end
    local bags, tray = CheckBags(), CheckTray()
    local d = Diag()
    d.t, d.bags, d.tray = GetServerTime(), bags, tray
    d.duration, d.cvar = Deposits.Duration(), C_CVar.GetCVar("auctionHouseDurationDropdown")
    d.names = {}
    for k = 1, DURATIONS do d.names[k] = Deposits.DurationName(k) end
    if bags + tray > 0 then ns.Fire("DEPOSITS_CHANGED") end
end

local function Schedule(delay)
    if not pending then pending = C_Timer.NewTimer(delay, Run) end
end

-- /bf diag: does the formula still match the game?
function Deposits.PrintDiag()
    local d = ns.db and ns.db.diag.deposits
    if not d then return end
    local known = 0
    for _ in pairs(ns.db.deposits) do known = known + 1 end
    ns.Print(string.format("deposits: formula checked %d times, %d different from the game; %d items known as commodity or gear; duration %s (%s, CVar %s)",
        d.checks or 0, d.mismatched or 0, known, tostring(d.duration or "-"), Deposits.DurationName(d.duration),
        tostring(d.cvar)))
    local m = d.mismatches and d.mismatches[1]
    if m then
        ns.Print(string.format("deposits: first difference: item %d (%s) x%d, duration %d: game %s, formula %s", m.itemID,
            m.kind, m.qty, m.duration, tostring(m.game), tostring(m.formula)))
    end
    if d.single or d.away then
        ns.Print(string.format("deposits: 1 unit of %s costs %s (formula %s); away from the AH the call gave %s",
            tostring(d.single and d.single.itemID or "-"), tostring(d.single and d.single.game or "-"),
            tostring(d.single and d.single.formula or "-"), tostring(d.away and d.away.value or "-")))
    end
end

-- ---------------------------------------------------------------- events

ns.On("AH_OPEN", function()
    wipe(checked)
    Schedule(OPEN_DELAY)
end)

ns.On("AH_CLOSED", function()
    if pending then
        pending:Cancel()
        pending = nil
    end
end)

ns.On("TRAY_CHANGED", function()
    if ns.ahOpen then Schedule(CHANGE_DELAY) end
end)

ns.On("SCAN_DONE", function()
    if ns.ahOpen then Schedule(CHANGE_DELAY) end
end)

ns.On("LOGIN", function()
    C_Timer.After(AWAY_DELAY, function()
        if not ns.db or ns.readOnlyDB or ns.ahOpen then return end
        local ok, value = pcall(C_AuctionHouse.CalculateCommodityDeposit, 2589, 1, 1)
        Diag().away = { ok = ok, value = type(value) == "number" and value or tostring(value), t = GetServerTime() }
    end)
end)

-- ---------------------------------------------------------------- self test

function Deposits.SelfTest(report)
    local passed, failed = 0, 0
    local function check(name, ok, detail)
        if ok then passed = passed + 1 else failed = failed + 1 end
        report(name, ok, detail)
    end
    local name = Deposits.DurationName(9)
    check("DEP-NAME", name == string.format(L["duration %d"], 9), "an unknown duration still gets a name: " .. name)
    local thread = ns.Econ.DepositPerUnit(Deposits.VendorSell(2320), 2, 2, true)
    check("DEP-THREAD", thread == 50, string.format("2 Coarse Thread (vendor %dc) for 8 hours: %s each (the sell frame said 1s for both)",
        Deposits.VendorSell(2320), tostring(thread)))
    local fixed, follow = Deposits.Duration({ depositDuration = 3 }), Deposits.Duration({ depositDuration = 0 })
    check("DEP-DURATION", fixed == 3 and follow >= 1 and follow <= DURATIONS,
        string.format("fixed in the settings: %s; 0 follows the sell frame: %s", Deposits.DurationName(fixed),
            Deposits.DurationName(follow)))
    return passed, failed
end
