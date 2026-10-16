# The auction house on Forever

Forever has only the **modern** auction house: `C_AuctionHouse` (85 functions, all present on 70374) and
`Blizzard_AuctionHouseUI` (LoadOnDemand, with a Forever category file `Camelot\Blizzard_AuctionData.lua`).
The Classic API (`QueryAuctionItems`, `GetAuctionItemInfo`, getAll scans) is gone, and lint flags it [F-120].

**Sources and licensing.** Everything here comes from Blizzard's forever-branch API docs, Blizzard's own
`Blizzard_AuctionHouseUI` source (`%LOCALAPPDATA%\wowf\wow-ui-source\Interface\AddOns\`), the WowfProbe dump
and in-game probes. Auctionator is All Rights Reserved and its authors forbid using it as a reference; check
any other AH addon's license (TSM is a commercial product) before reading it. You don't need them: Blizzard's
AH frame code shows every flow below.

## When you can query
- Only while the player is at an auctioneer: between `AUCTION_HOUSE_SHOW` and `AUCTION_HOUSE_CLOSED`, or
  `PLAYER_INTERACTION_MANAGER_FRAME_SHOW/HIDE(type)` with `Enum.PlayerInteractionType.Auctioneer` (21).
- Prices are copper, typed `BigUInteger` (a plain Lua number to addons; copper fits easily).
- Scanning (replicate, browse, search) has no restriction flags. Posting, bidding, buying and cancelling are
  `HasRestrictions`: inform the player and let them click; never automate (golden rule 15).
- Nothing here is secret: normal math and table keys are fine.

## Full scan: ReplicateItems
Blizzard's docs: "This function should be used in place of an 'allItem' QueryAuctionItems call to query the
entire auction house."
1. `C_AuctionHouse.ReplicateItems()`, once. The cooldown on Forever is unknown (retail: one per 15 minutes);
   record what you observe in forever-facts.md.
2. Wait for `REPLICATE_ITEM_LIST_UPDATE`.
3. `n = C_AuctionHouse.GetNumReplicateItems()`, then `GetReplicateItemInfo(i)` for `i = 0 .. n-1`. The index
   is typed `number`, not `luaIndex`, and is 0-based on retail; confirm it with the probe below [F-121].
4. The 18 returns: `name?, texture?, count, qualityID, usable?, level, levelType?, minBid, minIncrement,
   buyoutPrice, bidAmount, highBidder?, bidderFullName?, owner?, ownerFullName?, saleStatus, itemID, hasAllInfo?`.
   - `buyoutPrice` is for the whole stack: unit price = `buyoutPrice / count`. 0 means bid-only; skip it.
   - `name`, `texture` and `GetReplicateItemLink(i)` stay nil until the item is cached (`hasAllInfo`). Pricing
     by `itemID` doesn't need them; load names later only for items you display.
5. Process in time slices so the client never freezes, and abort if the AH closes.

```lua
local addonName, ns = ...
local BUDGET_MS = 8   -- per frame

-- acc[itemID] = { unitPrice1, qty1, unitPrice2, qty2, ... } (flat pairs keep garbage low)
function ns.ProcessReplicate(onDone)
    local n = C_AuctionHouse.GetNumReplicateItems()
    local i, acc = 0, {}
    local function step()
        if not ns.ahOpen then return end                    -- AUCTION_HOUSE_CLOSED clears ns.ahOpen
        local stop = debugprofilestop() + BUDGET_MS
        while i < n and debugprofilestop() < stop do
            local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = C_AuctionHouse.GetReplicateItemInfo(i)
            if itemID and count and count > 0 and buyout and buyout > 0 then
                local t = acc[itemID]
                if not t then t = {}; acc[itemID] = t end
                t[#t + 1] = buyout / count
                t[#t + 1] = count
            end
            i = i + 1
        end
        if i < n then C_Timer.After(0, step) else onDone(acc, n) end
    end
    step()
end
```

## Targeted searches (one item, current prices)
- `itemKey = C_AuctionHouse.MakeItemKey(itemID)` → `{itemID, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0}`.
- Commodity or item? `C_AuctionHouse.GetItemKeyInfo(itemKey).isCommodity`; the info can be nil until
  `ITEM_KEY_ITEM_INFO_RECEIVED(itemID)`. `GetItemCommodityStatus` takes an ItemLocation (a bag slot), not an ID.
  Blizzard's frame branches the same way (`Blizzard_AuctionHouseFrame.lua`, `SelectBrowseResult`).
- Send: `C_AuctionHouse.SendSearchQuery(itemKey, sorts, separateOwnerItems)` with
  `sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }`. The docs cap search
  queries at **100 per minute** and say not to use them for full scans.
- Commodity results: `COMMODITY_SEARCH_RESULTS_UPDATED(itemID)` → `GetNumCommoditySearchResults(itemID)` and
  `GetCommoditySearchResultInfo(itemID, i)` (1-based) → `{quantity, unitPrice, auctionID, owners, ...}`.
- Item results: `ITEM_SEARCH_RESULTS_UPDATED(itemKey, newAuctionID?)` → `GetNumItemSearchResults(itemKey)` and
  `GetItemSearchResultInfo(itemKey, i)` → `{quantity, buyoutAmount?, itemLink?, ...}`; `buyoutAmount` is nil
  for bid-only auctions.
- More rows: `RequestMoreCommoditySearchResults` / `RequestMoreItemSearchResults` until `HasFull*SearchResults`.
- Throttle: send only when `C_AuctionHouse.IsThrottledMessageSystemReady()` is true; otherwise wait for
  `AUCTION_HOUSE_THROTTLED_SYSTEM_READY`. Keep your own queue with one query in flight (Blizzard's sell frame
  checks the same function before posting).
- Your searches also refresh Blizzard's AH frame if it shows the same item. That's expected.

## Deposits and the house cut
- `CalculateCommodityDeposit(itemID, duration, quantity)` and `CalculateItemDeposit(itemLocation, duration,
  quantity)`: `duration` is a `luaIndex` (1..3, the sell frame's durations). Cache the per-unit result.
- There is **no API or constant for the cut** [F-122]. Measure it from seller invoices at the mailbox:
  `GetInboxInvoiceInfo(i)` (undocumented, present) → `invoiceType, itemName, playerName, bid, buyout, deposit,
  consignment`; for `"seller"`, `bid` is the sale total and `consignment` the cut, so rate = consignment / bid.
  Retail's cut is 5%; keep it a setting until measured.
- `C_AuctionHouse.SupportsCopperValues()`: when false, Blizzard's sell frame rounds prices to whole silver.
- `Constants.AuctionConstants.DEFAULT_AUCTION_PRICE_MULTIPLIER = 1.5` is Blizzard's default price (vendor x 1.5).

## Storing prices in SavedVariables
- **Key by market.** The AH is per ruleset [F-081]. Put the key in one function (realm and faction until the
  probes show what's shared) so it can change in one place, and keep Hardcore separate
  (`C_GameRules.IsHardcoreActive()`). Never key on character name-realm [F-080].
- **Store aggregates, not listings.** Per item and day: market value, min buyout, quantity, auction count. Keep the
  latest price ladder (up to ~8 price levels with quantities) for depth-aware costs. Prune at login (14–30 days).
  The estimators are in the `wowf-economics` skill.
- **Pack it.** A day number (`math.floor(GetServerTime() / 86400)`) and one string per item-day (`"mv:min:qty:n"`)
  keep the file small. SavedVariables load at login and save at logout or `/reload`; huge files slow both.
- `SAVED_VARIABLES_TOO_LARGE(addOnName)` exists and Blizzard shows a popup for it [F-127]. Whether data is
  dropped at load or at save isn't verified on Forever: stay small, and if it fires for your addon, stop
  writing and tell the player.

## Bag clicks while the AH is open
- A plain click on a bag item posts it (Blizzard calls `AuctionHouseFrame:SetPostItem(location)` after
  `IsSellItemValid`). Don't override it.
- Alt+Right-click is free [F-125]. Post-hook it:
  `hooksecurefunc("HandleModifiedItemClick", function(link, itemLocation) ... end)`, then check `IsAltKeyDown()`
  and `GetMouseButtonClicked() == "RightButton"`. Mixin hooks miss buttons that already exist.

## Probes (paste in game; record results in forever-facts.md with the build)
- Presence: `/run print(type(C_AuctionHouse and C_AuctionHouse.ReplicateItems), type(QueryAuctionItems))` → `function nil`.
- Replicate index base (at the AH, after `/run C_AuctionHouse.ReplicateItems()` and the update event):
  `/run local n=C_AuctionHouse.GetNumReplicateItems() print(n,C_AuctionHouse.GetReplicateItemLink(0),C_AuctionHouse.GetReplicateItemLink(n))`
- Are reagents commodities? (Linen Cloth; run twice if it prints nil):
  `/run local i=C_AuctionHouse.GetItemKeyInfo(C_AuctionHouse.MakeItemKey(2589)) print(i and i.itemName,i and i.isCommodity)`
- Cut rate (after a sale, mailbox open):
  `/run for i=1,GetInboxNumItems() do local t,n,_,bid,_,dep,cut=GetInboxInvoiceInfo(i) if t=="seller" and bid and bid>0 then print(n,bid,dep,cut,format("%.2f%%",cut*100/bid)) end end`
- Pricing rules: `/run print(C_AuctionHouse.SupportsCopperValues(),C_AuctionHouse.IsThrottledMessageSystemReady())`
- Market keys: `/run print(GetRealmName(),GetNormalizedRealmName(),UnitFactionGroup("player"))`; compare listings
  seen by an Alliance and a Horde character, and across realms of one ruleset.
- Full-scan cooldown: call `ReplicateItems` twice a few minutes apart and note whether the second returns data.
