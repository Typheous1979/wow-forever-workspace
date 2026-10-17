local addonName, ns = ...

-- Item data that may not be cached yet: uncached lookups return nil, so request the load and
-- continue when it arrives (api-migration.md). Uses Blizzard's ContinuableContainer + Item mixin;
-- a failed load (an item this client doesn't have) still counts as done there. As a backstop,
-- Load gives up after LOAD_TIMEOUT seconds and continues with what it has.

local Items = {}
ns.Items = Items

local LOAD_TIMEOUT = 3

-- fn() runs once, when every item in itemIDs is loaded (at once if all are cached) or on timeout.
function Items.Load(itemIDs, fn)
    local done = false
    local function finish()
        if done then return end
        done = true
        fn()
    end
    local container = ContinuableContainer:Create()
    for _, itemID in ipairs(itemIDs) do
        container:AddContinuable(Item:CreateFromItemID(itemID))
    end
    container:ContinueOnLoad(finish)
    if not done then
        C_Timer.After(LOAD_TIMEOUT, function()
            if done then return end
            container:Cancel()
            finish()
        end)
    end
end

-- The item's link, or "item 2589" while it isn't cached.
function Items.Link(itemID)
    local _, link = C_Item.GetItemInfo(itemID)
    return link or ("item " .. itemID)
end
