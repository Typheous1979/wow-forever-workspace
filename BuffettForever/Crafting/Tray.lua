local addonName, ns = ...

-- The reagent tray: up to 25 reagents with quantities, saved per character in
-- BuffettForeverCharDB.tray = { { itemID, qty }, ... } (slot order). Adding an item that's already
-- there merges into its slot. A new item's quantity defaults to what you own (bags and bank) and what
-- BuffettForever bought for you that's still in the mailbox, at least 1; the evaluator crafts as many as
-- the tray quantities allow. A purchase is credited on top (Tray.Credit: it comes by mail, so the bags
-- don't show it yet). Fires TRAY_CHANGED.
-- Where a slot's units really are (Justin, 2026-10-18: a player would think a purchase is in the bags):
-- Tray.SlotState sets the slot's envelope, grey icon and orange count (UI/ReagentTray.lua). Crafting uses
-- the bags, and the bank only where Forever allows it (Blizzard's own rule: ReagentsFromBankAllowed).

local Tray = {}
ns.Tray = Tray

Tray.SIZE = 25
local MAX_QTY = 9999

local function Entries()
    return ns.charDB and ns.charDB.tray or {}
end

local function Changed()
    ns.Fire("TRAY_CHANGED")
end

function Tray.Entries()
    return Entries()
end

function Tray.Get(slot)
    return Entries()[slot]
end

function Tray.Find(itemID)
    for slot, entry in ipairs(Entries()) do
        if entry.itemID == itemID then return slot, entry end
    end
    return nil
end

local function Owned(itemID)
    return C_Item.GetItemCount(itemID, true) or 0
end

-- Whether crafting takes reagents from the bank too (Blizzard's ItemUtil.GetCraftingReagentCount asks this).
function Tray.BankUsable()
    return type(ReagentsFromBankAllowed) == "function" and ReagentsFromBankAllowed() == true
end

-- Units of an item crafting can use now: the bags, plus the banks where Forever allows them.
function Tray.UsableCount(itemID)
    local bank = Tray.BankUsable()
    return C_Item.GetItemCount(itemID, bank, false, bank, bank) or 0
end

-- Units in your banks (the bank, the reagent bank and the account bank).
function Tray.BankCount(itemID)
    local all = C_Item.GetItemCount(itemID, true, false, true, true) or 0
    return math.max(0, all - (C_Item.GetItemCount(itemID) or 0))
end

-- A slot's state from its quantity and where the item is: usable (what crafting can use), faded (none of it
-- can be used: the icon greys out) and short (the tray counts more than the bags, the banks and the mailbox
-- hold: the count turns orange). Pure, so the self-test runs it.
function Tray.SlotState(qty, bags, bank, mail, bankUsable)
    local usable = bags + (bankUsable and bank or 0)
    return usable, usable == 0, qty > bags + bank + mail
end

-- Add an item (qty defaults to what you own and what's on its way by mail, at least 1). Returns its slot, or
-- nil when the tray is full.
function Tray.Add(itemID, qty)
    if not ns.charDB then return nil end
    qty = math.min(MAX_QTY, qty or math.max(1, Owned(itemID) + ns.Collect.InMail(itemID)))
    local slot, entry = Tray.Find(itemID)
    if entry then
        entry.qty = math.max(entry.qty, qty)
        Changed()
        return slot
    end
    local entries = Entries()
    if #entries >= Tray.SIZE then return nil end
    entries[#entries + 1] = { itemID = itemID, qty = qty }
    Changed()
    return #entries
end

-- Add n units to an item's slot, or to a free one. Returns the slot, or nil when the tray is full.
-- entries: the tray's list (pure, so the self-test runs it).
function Tray.CreditEntries(entries, itemID, n)
    for slot, entry in ipairs(entries) do
        if entry.itemID == itemID then
            entry.qty = math.min(MAX_QTY, entry.qty + n)
            return slot
        end
    end
    if #entries >= Tray.SIZE then return nil end
    entries[#entries + 1] = { itemID = itemID, qty = math.min(MAX_QTY, n) }
    return #entries
end

-- A purchase (Pricing/Buy.lua): n units on top of what the tray holds.
function Tray.Credit(itemID, n)
    if not ns.charDB then return nil end
    local slot = Tray.CreditEntries(Entries(), itemID, n)
    if slot then Changed() end
    return slot
end

-- Whether a purchase of the item can be credited: it's in the tray, or a slot is free.
function Tray.HasRoom(itemID)
    return Tray.Find(itemID) ~= nil or #Entries() < Tray.SIZE
end

function Tray.Remove(slot)
    local entries = Entries()
    if not entries[slot] then return end
    table.remove(entries, slot)
    Changed()
end

function Tray.SetQty(slot, qty)
    local entry = Entries()[slot]
    if not entry then return end
    entry.qty = math.max(1, math.min(MAX_QTY, qty))
    Changed()
end

function Tray.Clear()
    wipe(Entries())
    Changed()
end

-- What Load from bags puts in the tray: counts ({ [itemID] = in the bags }) plus mail ({ [itemID] = bought,
-- still in the mailbox }), so a purchase not collected yet stays; only reagents (uses(itemID) -> the recipes
-- that use it, and how many of those this character knows), the ones your known recipes need first, then
-- by recipes, then by how many. Pure, so the self-test runs it.
function Tray.LoadCandidates(counts, mail, uses)
    local total = {}
    for itemID, n in pairs(counts) do total[itemID] = n end
    for itemID, n in pairs(mail) do
        if n > 0 then total[itemID] = (total[itemID] or 0) + n end
    end
    local candidates = {}
    for itemID, qty in pairs(total) do
        local n, known = uses(itemID)
        if n > 0 then
            candidates[#candidates + 1] = { itemID = itemID, qty = math.min(MAX_QTY, qty), uses = n, known = known }
        end
    end
    table.sort(candidates, function(a, b)
        if a.known ~= b.known then return a.known > b.known end
        if a.uses ~= b.uses then return a.uses > b.uses end
        if a.qty ~= b.qty then return a.qty > b.qty end
        return a.itemID < b.itemID
    end)
    return candidates
end

-- Fill the tray with the reagents in your bags (and on their way by mail) that the most recipes use.
-- Returns how many reagents were found.
function Tray.LoadFromBags()
    if not ns.charDB then return 0 end
    local counts = {}
    for bag = Enum.BagIndex.Backpack, Enum.BagIndex.ReagentBag do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID then
                counts[info.itemID] = (counts[info.itemID] or 0) + (info.stackCount or 1)
            end
        end
    end
    local mail = {}
    for _, e in ipairs(ns.Collect.Summary()) do mail[e.itemID] = e.q end
    local candidates = Tray.LoadCandidates(counts, mail, function(itemID)
        local n = #ns.RecipeIndex.UsingReagent(itemID, { confirmed = true })
        if n == 0 then return 0, 0 end
        return n, #ns.RecipeIndex.UsingReagent(itemID, { known = "char" })
    end)
    local entries = Entries()
    wipe(entries)
    for i = 1, math.min(Tray.SIZE, #candidates) do
        entries[i] = { itemID = candidates[i].itemID, qty = candidates[i].qty }
    end
    Changed()
    return #candidates
end

-- ---------------------------------------------------------------- self-test

function Tray.SelfTest(report)
    local passed, failed = 0, 0
    local function check(name, ok, detail)
        if ok then passed = passed + 1 else failed = failed + 1 end
        report(name, ok, detail)
    end
    local S = Tray.SlotState
    local u1, f1, s1 = S(3, 6, 0, 3, false)
    local u2, f2, s2 = S(3, 0, 0, 3, false)
    local u3, f3, s3 = S(3, 0, 2, 0, false)
    local u4, f4, s4 = S(3, 0, 2, 0, true)
    local _, f5, s5 = S(5, 2, 0, 3, false)
    check("TRAY-SLOT", u1 == 6 and not f1 and not s1 and u2 == 0 and f2 and not s2 and u3 == 0 and f3 and s3
        and u4 == 2 and not f4 and s4 and not f5 and not s5,
        "3 with 6 in the bags: in colour; 3 all in the mail: grey; 3 with 2 in the bank: grey and short, or in colour "
            .. "and short where the bank counts; 5 as 2 + 3 in the mail: not short")
    local uses = { [1] = 2, [2] = 1, [3] = 0 }
    local list = Tray.LoadCandidates({ [1] = 6, [3] = 4 }, { [1] = 3, [2] = 2 }, function(itemID) return uses[itemID] or 0, 0 end)
    local byID = {}
    for _, c in ipairs(list) do byID[c.itemID] = c.qty end
    check("TRAY-LOAD-MAIL", #list == 2 and byID[1] == 9 and byID[2] == 2 and byID[3] == nil and list[1].itemID == 1,
        "6 in the bags and 3 in the mail: 9; a reagent only in the mail stays; an item no recipe uses doesn't")
    return passed, failed
end
