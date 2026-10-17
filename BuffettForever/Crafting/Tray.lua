local addonName, ns = ...

-- The reagent tray: up to 10 reagents with quantities, saved per character in
-- BuffettForeverCharDB.tray = { { itemID, qty }, ... } (slot order). Adding an item that's already
-- there merges into its slot. A new item's quantity defaults to what you own (bags and bank), at
-- least 1; the evaluator crafts as many as the tray quantities allow. Fires TRAY_CHANGED.

local Tray = {}
ns.Tray = Tray

Tray.SIZE = 10
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

-- Add an item (qty defaults to what you own, at least 1). Returns its slot, or nil when the tray is full.
function Tray.Add(itemID, qty)
    if not ns.charDB then return nil end
    qty = math.min(MAX_QTY, qty or math.max(1, Owned(itemID)))
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

-- Fill the tray with the reagents in your bags that the most recipes use: the ones your known
-- recipes need first, then by confirmed recipes, then by how many you carry. Returns how many
-- reagents were found.
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
    local candidates = {}
    for itemID, count in pairs(counts) do
        local uses = #ns.RecipeIndex.UsingReagent(itemID, { confirmed = true })
        if uses > 0 then
            candidates[#candidates + 1] = {
                itemID = itemID, qty = math.min(MAX_QTY, count), uses = uses,
                known = #ns.RecipeIndex.UsingReagent(itemID, { known = "char" }),
            }
        end
    end
    table.sort(candidates, function(a, b)
        if a.known ~= b.known then return a.known > b.known end
        if a.uses ~= b.uses then return a.uses > b.uses end
        if a.qty ~= b.qty then return a.qty > b.qty end
        return a.itemID < b.itemID
    end)
    local entries = Entries()
    wipe(entries)
    for i = 1, math.min(Tray.SIZE, #candidates) do
        entries[i] = { itemID = candidates[i].itemID, qty = candidates[i].qty }
    end
    Changed()
    return #candidates
end
