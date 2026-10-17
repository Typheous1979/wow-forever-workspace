local addonName, ns = ...

-- Alt+Right-click on an item adds it to the reagent tray. At the Auction House it also searches
-- the item's current listings and prints them with the deposit (for one and for all you carry, at
-- the duration Blizzard's sell frame uses); anywhere else it says what was added, with the stored AH
-- price. A post-hook on HandleModifiedItemClick: bag buttons send every modified click
-- there, and a modified click never uses, sells or posts the item; Alt+Right-click isn't bound to
-- anything on Forever [F-125]. Plain clicks stay Blizzard's. Item links Alt+Right-clicked
-- elsewhere (chat, loot) work the same way.

local L = ns.L
local Money = ns.Money

-- n: auctions (full scans, item searches); prices: price levels (commodity searches group by price);
-- own: your own units, left out of the market.
local function Listed(link, mv, min, q, n, prices, own)
    local text = string.format(L["%s: market %s, min buyout %s, %s listed"], link, Money.Format(mv),
        Money.Format(min), BreakUpLargeNumbers(q))
    if n then
        text = text .. " " .. string.format(L["in %s auctions"], BreakUpLargeNumbers(n))
    elseif prices then
        text = text .. " " .. string.format(L["at %s prices"], BreakUpLargeNumbers(prices))
    end
    if own and own > 0 then text = text .. " " .. string.format(L["(plus %d of yours, left out)"], own) end
    return text
end

-- " Vendor pays 1c." when the item can be sold to a vendor (0 or unknown: nothing).
local function VendorText(itemID)
    local sell = ns.ItemSellPrice and ns.ItemSellPrice[itemID] or select(11, C_Item.GetItemInfo(itemID))
    if type(sell) ~= "number" or sell <= 0 then return "" end
    return " " .. string.format(L["Vendor pays %s."], Money.Format(sell))
end

-- " Deposit for 8 Hours: 1s for 1, 1s for all 20." at the AH, by Forever's formula [F-129] (gear: per
-- auction). The bag slot also lets Deposits check the formula against the game.
local function DepositText(itemID, itemLocation)
    local D, Econ = ns.Deposits, ns.Econ
    if type(itemLocation) == "table" then D.CheckLocation(itemLocation) end
    local d, sell = D.Duration(), D.VendorSell(itemID)
    if not D.IsCommodity(itemID) then
        return " " .. string.format(L["Deposit for %s: %s per auction."], D.DurationName(d), Money.Format(Econ.Deposit(sell, 1, d)))
    end
    local text = string.format(L["Deposit for %s: %s for 1"], D.DurationName(d), Money.Format(Econ.Deposit(sell, 1, d)))
    local have = C_Item.GetItemCount(itemID) or 0
    if have > 1 then
        text = text .. string.format(L[", %s for all %d"], Money.Format(Econ.Deposit(sell, have, d)), have)
    end
    return " " .. text .. "."
end

-- Into the tray; returns the slot or nil (full: said so).
local function AddToTray(itemID)
    local slot = ns.Tray.Add(itemID)
    if not slot then ns.Print(string.format(L["The tray is full (%d reagents)."], ns.Tray.SIZE)) end
    return slot
end

local function Added(itemID, link)
    local _, entry = ns.Tray.Find(itemID)
    local text = string.format(L["Added %s x%d to the tray."], link, entry and entry.qty or 1)
    local row, age = ns.PriceDB.Get(itemID)
    if row then
        text = text .. " " .. string.format(L["AH market %s (%s ago)."], Money.Format(row.mv), ns.FormatAge(age))
    end
    ns.Print(text .. VendorText(itemID))
end

local function PriceCheck(itemID, link, itemLocation, inTray)
    local key
    if type(itemLocation) == "table" and C_Item.DoesItemExist(itemLocation) then
        key = C_AuctionHouse.GetItemKeyFromItem(itemLocation)
    end
    if ns.Scanner.IsBusy() and not ns.Search.IsQueued(itemID) then
        ns.Print(string.format(L["%s: queued until the full scan finishes."], link))
    end
    local tail = DepositText(itemID, itemLocation) .. (inTray and (" " .. L["(In the tray.)"]) or "")
    ns.Search.Request(itemID, key, function(_, result, problem)
        if result then
            local text = Listed(link, result.mv, result.min, result.q, result.n, result.prices, result.own) .. "."
            if not result.full then text = text .. " " .. L["(Only the cheapest listings were read.)"] end
            ns.Print(text .. VendorText(itemID) .. tail)
        else
            ns.Print(link .. ": " .. (problem or "?") .. VendorText(itemID) .. tail)
        end
    end)
end

hooksecurefunc("HandleModifiedItemClick", function(link, itemLocation)
    if not IsAltKeyDown() or GetMouseButtonClicked() ~= "RightButton" then return end
    if type(link) ~= "string" or not ns.db then return end
    local itemID = C_Item.GetItemInfoInstant(link)
    if not itemID then return end
    local slot = AddToTray(itemID)
    if ns.ahOpen then
        PriceCheck(itemID, link, itemLocation, slot ~= nil)
    elseif slot then
        Added(itemID, link)
    end
end)
