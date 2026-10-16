local addonName, ns = ...

-- Alt+Right-click on an item: at the Auction House, search its current listings and print
-- them; anywhere else, print the stored prices. A post-hook on HandleModifiedItemClick: bag
-- buttons send every modified click there, and a modified click never uses, sells or posts
-- the item; Alt+Right-click isn't bound to anything on Forever [F-125]. Plain clicks stay
-- Blizzard's. Item links Alt+Right-clicked elsewhere (chat, loot) work the same way.
-- Adding the item to the reagent tray comes in M3.

local L = ns.L
local Money = ns.Money

local function Listed(link, mv, min, q, n)
    return string.format(L["%s: market %s, min buyout %s, %s listed in %s auctions"], link, Money.Format(mv),
        Money.Format(min), BreakUpLargeNumbers(q), BreakUpLargeNumbers(n))
end

-- " Vendor pays 1c." when the item can be sold to a vendor (0 or uncached: nothing).
local function VendorText(itemID)
    local sell = select(11, C_Item.GetItemInfo(itemID))
    if type(sell) ~= "number" or sell <= 0 then return "" end
    return " " .. string.format(L["Vendor pays %s."], Money.Format(sell))
end

local function PrintStored(itemID, link)
    local row, age = ns.PriceDB.Get(itemID)
    if row then
        ns.Print(Listed(link, row.mv, row.min, row.q, row.n) .. " " .. string.format(L["(%s ago)."], ns.FormatAge(age))
            .. VendorText(itemID))
    else
        ns.Print(string.format(L["%s: no Auction House data yet."], link) .. VendorText(itemID))
    end
end

local function PriceCheck(itemID, link, itemLocation)
    local key
    if type(itemLocation) == "table" and C_Item.DoesItemExist(itemLocation) then
        key = C_AuctionHouse.GetItemKeyFromItem(itemLocation)
    end
    if ns.Scanner.IsBusy() and not ns.Search.IsQueued(itemID) then
        ns.Print(string.format(L["%s: queued until the full scan finishes."], link))
    end
    ns.Search.Request(itemID, key, function(_, result, problem)
        if result then
            local text = Listed(link, result.mv, result.min, result.q, result.n) .. "."
            if not result.full then text = text .. " " .. L["(Only the cheapest listings were read.)"] end
            ns.Print(text .. VendorText(itemID))
        else
            ns.Print(link .. ": " .. (problem or "?") .. VendorText(itemID))
        end
    end)
end

hooksecurefunc("HandleModifiedItemClick", function(link, itemLocation)
    if not IsAltKeyDown() or GetMouseButtonClicked() ~= "RightButton" then return end
    if type(link) ~= "string" or not ns.db then return end
    local itemID = C_Item.GetItemInfoInstant(link)
    if not itemID then return end
    if ns.ahOpen then
        PriceCheck(itemID, link, itemLocation)
    else
        PrintStored(itemID, link)
    end
end)
