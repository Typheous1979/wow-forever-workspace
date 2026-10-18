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
  `HasRestrictions`. Never automate them: an addon acts only inside the player's own click (or typed command), one
  action per click, with the price shown first; never from a timer, a queue or an event. Forever allows that for
  buying commodities and gear [F-132] and for posting a commodity [F-136]; see "Buying" and "Posting".
- Nothing here is secret: normal math and table keys are fine.

## Full scan: ReplicateItems
Blizzard's docs: "This function should be used in place of an 'allItem' QueryAuctionItems call to query the
entire auction house."
1. `C_AuctionHouse.ReplicateItems()`, once. Inside the cooldown (over 2 min on 70425; retail: 15 min) the request
   is **ignored**: no event ever comes. Start a timeout and tell the player; 60 s is plenty, since 62k rows arrived in
   4.7 s [F-121].
2. Wait for the **first** `REPLICATE_ITEM_LIST_UPDATE`. It fires again, thousands of times, as item data arrives
   for the rows you read, so ignore repeats while you read (a state flag).
3. `n = C_AuctionHouse.GetNumReplicateItems()`, then `GetReplicateItemInfo(i)` for `i = 0 .. n-1`. The index is
   typed `number`, not `luaIndex`, and is **0-based** on 70425. Index `n` returns `itemID 0, count -1`, not nil, so
   skip `itemID == 0` if you probe past the end [F-121].
4. The 18 returns: `name?, texture?, count, qualityID, usable?, level, levelType?, minBid, minIncrement,
   buyoutPrice, bidAmount, highBidder?, bidderFullName?, owner?, ownerFullName?, saleStatus, itemID, hasAllInfo?`.
   - `buyoutPrice` is for the whole stack: unit price = `buyoutPrice / count`. 0 means bid-only; skip it.
   - `name`, `texture` and `GetReplicateItemLink(i)` stay nil until the item is cached (`hasAllInfo`; 8.7% of rows
     on the beta). Pricing by `itemID` doesn't need them; load names later only for items you display.
5. Process in time slices so the client never freezes, and abort if the AH closes. At 8 ms per frame, 62k rows took
   0.7 s to read [F-128].
6. **Item data is still loading when the read ends.** Anything you need from `C_Item.GetItemInfo` (a vendor sell
   price, a class) is nil for many items until they're cached: 1,309 of 2,927 items right after a 54k-row scan on
   70425. Keep those items' listings, load them (`ContinuableContainer` with `Item:CreateFromItemID`, plus a
   timeout), then decide. BuffettForever `Flips.Recheck` 0.7.0: on 70425 the next scan left 1,305 items unpriced;
   all of them loaded inside its 20 s timeout, and 5 more flips turned up.

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

## Blizzard's AH frame, and a button on it
- `AUCTION_HOUSE_SHOW` → Blizzard's `GameEvent.HandleAuctionHouseShow` → `ShowAuctionHouseFrame()`, which loads
  `Blizzard_AuctionHouseUI` (its `ADDON_LOADED` fires) and shows `AuctionHouseFrame`. The frame's `OnHide` calls
  `C_AuctionHouse.CloseAuctionHouse()`, so closing the window ends the session (`AUCTION_HOUSE_CLOSED`); ignore a
  repeated CLOSED. (`Blizzard_Game\Mainline\EventImplementation.lua`, `Blizzard_AuctionHouseFrame.lua`)
- **A scan button on it** (works on 70425, BuffettForever `UI\AHButton.lua`):
  - Use your own `UIPanelButtonTemplate` button parented to `AuctionHouseFrame`.
  - Make it on `ADDON_LOADED("Blizzard_AuctionHouseUI")`, or at `AUCTION_HOUSE_SHOW` if that addon already loaded.
    Keep `ADDON_LOADED` registered after your own load.
  - Place it under the frame, right of the Buy/Sell/Auctions tabs (they hang below the frame on the left):
    `SetPoint("TOPRIGHT", AuctionHouseFrame, "BOTTOMRIGHT", -6, -2)`.
  - No secure attributes, no hooks, and nothing written into Blizzard's frame table.

## Targeted searches (one item, current prices)
Working code: BuffettForever `Pricing\Search.lua` (tested on 70425).
- **The key:**
  - `itemKey = C_AuctionHouse.MakeItemKey(itemID)` → `{itemID, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0}`.
  - For a bag item, take Blizzard's exact key: `C_AuctionHouse.GetItemKeyFromItem(itemLocation)`. That's what the
    sell frame does.
- **Commodity, equipment or item?**
  - `C_AuctionHouse.GetItemKeyInfo(itemKey)` → `.isCommodity`, `.isEquipment`. The info can be nil until
    `ITEM_KEY_ITEM_INFO_RECEIVED(itemID)`.
  - Without it, item class 2/4 (`Enum.ItemClass.Weapon/Armor` from `C_Item.GetItemInfoInstant`) means equipment.
    For anything else, the results event tells commodity from item.
  - `GetItemCommodityStatus` takes an ItemLocation (a bag slot), not an ID. Blizzard's frame branches the same way
    (`Blizzard_AuctionHouseFrame.lua`, `SelectBrowseResult`).
- **Send:**
  - Commodities and plain items: `C_AuctionHouse.SendSearchQuery(itemKey, sorts, separateOwnerItems)` with
    `sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }`.
  - Equipment: `C_AuctionHouse.SendSellSearchQuery(key, sorts, false)` with `itemLevel` and `itemSuffix` set to 0.
    That returns every variant, as Blizzard's sell frame does (`AuctionHouseUtil.ConvertItemSellItemKey`).
  - The docs cap search queries at **100 per minute** and say not to use them for full scans.
- **Commodity results:** `COMMODITY_SEARCH_RESULTS_UPDATED(itemID)` (or `_ADDED`) →
  `GetNumCommoditySearchResults(itemID)` and `GetCommoditySearchResultInfo(itemID, i)` (1-based) →
  `{quantity, unitPrice, auctionID, owners, ...}`.
  - Rows are **grouped by unit price**: 41 rows for 295 auctions on 70425 [F-121]. Sum the quantities, and don't
    count the rows as auctions.
- **Item results:** `ITEM_SEARCH_RESULTS_UPDATED(itemKey, newAuctionID?)` (or `_ADDED`) →
  `GetNumItemSearchResults(itemKey)` and `GetItemSearchResultInfo(itemKey, i)` → `{quantity, buyoutAmount?,
  itemLink?, ...}`.
  - `buyoutAmount` pays for the whole auction (Blizzard's buy frame bids it), so the unit price is
    `buyoutAmount / quantity`. It's nil for bid-only auctions.
- **More rows:** `RequestMoreCommoditySearchResults` / `RequestMoreItemSearchResults` (each returns
  `hasFullResults`; when true no event follows) until `HasFull*SearchResults`. The next page arrives as `*_ADDED`.
  On 70425 every test search came in one page in 0.1–0.4 s.
- Throttle: send only when `C_AuctionHouse.IsThrottledMessageSystemReady()` is true; otherwise wait for
  `AUCTION_HOUSE_THROTTLED_SYSTEM_READY`. Keep your own queue with one query in flight (Blizzard's sell frame
  checks the same function before posting).
- Your searches also refresh Blizzard's AH frame if it shows the same item. That's expected.
- **Your own auctions are in the results.** Commodity rows carry `numOwnerItems` (your units in that row), item
  rows `containsOwnerItem`. Leave them out before pricing. A full scan has no owner flag you can use without names,
  so subtract your own auctions (`GetOwnedAuctions`: quantity and unit price) from the listings at their price:
  BuffettForever `Econ.ExcludeOwn`.

## Buying (commodities)
Proven on 70450 from addon code inside a key press [F-132]. Blizzard's flow is in
`Shared\Blizzard_AuctionHouseBuyDialog.lua` and `Blizzard_AuctionHouseFrame.lua` [Source 70450]:
1. **Quote:** `C_AuctionHouse.StartCommoditiesPurchase(itemID, quantity)` → `COMMODITY_PRICE_UPDATED(unitPrice,
   totalPrice)`, or `COMMODITY_PRICE_UNAVAILABLE` when that quantity isn't listed. Blizzard passes the preview unit
   price as an undocumented third argument; the documented two worked. The quote holds for **30 s**
   (`GetQuoteDurationRemaining()`, whole seconds).
2. **Check the quote against the price you showed.** Blizzard refuses a unit price more than 5% over its preview
   (`MAXIMUM_PREVIEW_PRICE_DIFFERENTIAL = 1.05`). A smaller rise is shown as an increase before Buy Now is enabled.
3. **Buy:** `ConfirmCommoditiesPurchase(itemID, quantity)` → `COMMODITY_PURCHASE_SUCCEEDED` or `_FAILED`.
4. **Delivery:** the items come **by mail**, not to the bags [F-132]. Don't count the bags to see what was bought.
   Record the purchase yourself, so the player isn't told to buy it again before the mail is collected, and show
   that it's in the mailbox. BuffettForever keeps the units still in the mailbox per item and lowers them only when
   the mailbox shows them gone (see "Collecting AH mail"). Guessing from the bag count left units used before the
   mail was collected counted as "in the mail" for 30 days.
5. **The cost:** the quote is the most you pay. A purchase can cost less when cheaper listings appear before the
   confirm (once on 70450 [F-132]), so take the gold spent from `GetMoney()`.

What to know:
- **One quote at a time.** Blizzard's buy dialog uses the same quote and cancels whatever quote is open when it
  hides (`OnHide` → `CancelCommoditiesPurchase`). It also hides itself once `GetQuoteDurationRemaining()` reaches 0.
  Don't start a quote while `AuctionHouseFrame.BuyDialog` is shown. Cancel yours on `AUCTION_HOUSE_CLOSED`.
- **The events don't name the item** (except `COMMODITY_PURCHASED(itemID, quantity)`, which didn't fire before
  `SUCCEEDED` [F-132]). Act on them only while your own quote is open.
- Blizzard shows the countdown in the last 10 s (`REMAINING_QUOTE_DURATION_THRESHOLD`).
- Each call goes straight from a click handler (or a typed command), never from a timer, a queue or an event
  handler: one player action, one purchase.
- Check `GetMoney()` against the quote's total before confirming. Watch `ADDON_ACTION_BLOCKED` and
  `ADDON_ACTION_FORBIDDEN(addonName, func)` for your addon's name.
- Working code: BuffettForever `Pricing\Buy.lua` (`/bf buytest`, logged in `diag.purchases`).

## Buying gear (one auction)
Proven on 70450 from a button's click [F-132]. Blizzard's Buy button shows the `BUYOUT_AUCTION` popup, then calls
`PlaceBid` [Source 70450]:
1. **Search the item** (equipment with `SendSellSearchQuery`, see Targeted searches) and read each auction with
   `GetItemSearchResultInfo(itemKey, i)`: `auctionID`, `buyoutAmount` (for the whole auction), `quantity`,
   `containsOwnerItem`. Sort by `buyoutAmount ÷ quantity` and leave your own out.
2. **Show the auction and its price**, then let a second click buy it:
   `C_AuctionHouse.PlaceBid(auctionID, buyoutAmount)`. A bid equal to the buyout buys outright.
3. **`AUCTION_HOUSE_PURCHASE_COMPLETED(auctionID)`** names the auction (0.6 s later on 70450). Match it against
   yours. A failure comes as `AUCTION_HOUSE_SHOW_ERROR(error)` (untested on Forever): drop that auction.
4. **Delivery:** by mail, like commodities [F-132]. Exactly the buyout is spent.
5. **Search again** before offering the next auction: the results go stale once you buy.

What to know:
- The same rules as commodities: one call per click, the AH open, out of combat, `GetMoney()` checked first.
- `PlaceBid` is `HasRestrictions`, not protected. No popup is needed: Blizzard's is its own confirmation, and
  yours is the second click.
- Working code: BuffettForever `Pricing\Buy.lua` (`Buy.StartAuction`, `Buy.Confirm`), the AH flips tab.

## Posting (from a click)
Proven on 70450 for a commodity from a typed command, and for gear from a button's click [F-136]. Blizzard's flow is in
`Shared\Blizzard_AuctionHouseSellFrame.lua`, `...CommoditiesSellFrame.lua` and `...ItemSellFrame.lua` [Source 70450]:
1. **The item:** a bag slot as `ItemLocation:CreateFromBagAndSlot(bag, slot)`, then `IsSellItemValid(location,
   false)` and `GetItemCommodityStatus(location)` (2 = commodity, 1 = item). For a commodity,
   `GetAvailablePostCount(location)` is every unit in the bags, and one post takes from all stacks.
2. **The duration:** the sell frame's CVar `auctionHouseDurationDropdown` (1..3). **The deposit:**
   `CalculateCommodityDeposit(itemID, d, qty)` or `CalculateItemDeposit(location, d, qty)`, which can return nil, so
   fall back to the formula [F-129]. Blizzard requires `GetMoney()` ≥ the deposit and
   `IsThrottledMessageSystemReady()`.
3. **The price:** Blizzard's default **copies the cheapest listing exactly**, with no undercut. For commodities
   that's `GetCommoditySearchResultInfo(itemID, 1).unitPrice`; for items, the cheapest buyout at the same item level.
   With no listings it uses 1.5 × the vendor price, rounded up to a silver. Search first, and leave your own
   listings out.
4. **Post:** `PostCommodity(location, d, qty, unitPrice)` or `PostItem(location, d, qty, bid, buyout)`. Both return
   `needsConfirmation`. When it's true, `AUCTION_HOUSE_POST_WARNING` follows, and a second click sends the same
   arguments to `ConfirmPostCommodity` or `ConfirmPostItem`.
5. **The outcome:**
   - `AUCTION_HOUSE_AUCTION_CREATED(auctionID)` (303 ms on 70450), `AUCTION_HOUSE_POST_ERROR`, or
     `AUCTION_HOUSE_SHOW_ERROR(error)`.
   - An item posted several at once is a multisell: `AUCTION_MULTISELL_START(n)`, `_UPDATE(created, total)`,
     `_FAILURE`, stopped with `CancelSell()`.
   - `GetMoney()` hadn't changed yet at `AUCTION_CREATED`, so read the deposit later.

What to know:
- **The popup trap.** Blizzard's `AuctionHouseFrame` answers `AUCTION_HOUSE_POST_WARNING` with its own StaticPopup,
  whose Accept confirms only Blizzard's own cached post (the sell frames' `pendingPost`). For an addon's post it does
  nothing.
  - Don't hide that popup from addon code: `StaticPopup_Hide` taints the shared popup frames. Tell the player to
    confirm in your UI.
  - Before posting, read `pendingPost` (reading is fine): if Blizzard has a stale one, its Accept would confirm that
    post instead.
  - Don't drive Blizzard's sell frame (`AuctionHouseFrame:SetPostItem`) from addon code either.
- No warning came for a post at the cheapest listing [F-136]; when it comes is still unknown.
- Working code: BuffettForever `Pricing\Post.lua` (`/bf posttest`, logged in `diag.posts`).

## Deposits and the house cut
- `CalculateCommodityDeposit(itemID, duration, quantity)` and `CalculateItemDeposit(itemLocation, duration,
  quantity)`: `duration` is a `luaIndex` (1..3, the sell frame's durations). Cache the per-unit result.
  - Blizzard's sell frames call exactly these for the deposit they display. The duration index (named
    `AUCTION_DURATION_ONE/TWO/THREE`) is remembered in the CVar `auctionHouseDurationDropdown`, so
    `C_CVar.GetCVar("auctionHouseDurationDropdown")` is the duration the player will post with [Source 70450].
  - Commodities need only the itemID. Items need a bag slot (`ItemLocation:CreateFromBagAndSlot`; check
    `C_AuctionHouse.IsSellItemValid(location, false)` and `GetItemCommodityStatus(location)` first).
  - **On Forever the formula is known** [F-129]: durations 2, 8 and 24 hours, and
    `deposit = max(100, floor(vendorSell × quantity / 20) × ({1, 4, 12})[duration])` copper **per auction**.
    Compute it for any item and quantity, and keep the calls to check it after a new build. Divide by 20 rather
    than multiply by 0.05, so the floor is exact for integer prices.
  - **The 1s minimum is per auction**, so the deposit per unit depends on how many you post at once: 2 Coarse
    Thread cost 50c each, 200 cost 0.5c each. One auction per item for gear (non-commodities).
- There is **no API or constant for the cut** [F-122]. Measure it from seller invoices at the mailbox:
  `GetInboxInvoiceInfo(i)` (undocumented, present) → `invoiceType, itemName, playerName, bid, buyout, deposit,
  consignment`; for `"seller"`, `bid` is the sale total and `consignment` the cut, so rate = consignment / bid.
  Retail's cut is 5%; keep it a setting until measured.
- `C_AuctionHouse.SupportsCopperValues()`: when false, Blizzard's sell frame rounds prices to whole silver.

## Sales mail and your auctions (a sales ledger)
The calls below are runtime-only (undocumented, present on 70374). Their returns are as Blizzard's
`Blizzard_MailFrame\MailFrame.lua` reads them [Source 70450]:
- `GetInboxNumItems()` → numItems, totalItems.
- `GetInboxHeaderInfo(i)` → packageIcon, stationeryIcon, sender, subject, money, CODAmount, daysLeft, itemCount,
  wasRead, wasReturned, textCreated, canReply, isGM, firstItemQuantity, firstItemLink.
- `GetInboxInvoiceInfo(i)` → invoiceType (`"seller"`, `"seller_temp_invoice"`, `"buyer"`, nil for other mail),
  itemName, playerName (nil means several), bid (the sale total for `count` units), buyout, deposit, consignment
  (the house cut), moneyDelay, etaHour, etaMin, count, commerceAuction. A seller receives bid + deposit − consignment.
- `GetInboxItem(i, slot)` → name, itemID, texture, count, quality, canUse, isCurrency (slots 1 to
  `ATTACHMENTS_MAX_RECEIVE` = 16, defined in MailFrame.lua).

What to know when building on them:
- Blizzard calls `GetInboxText` only when the player opens a mail [Source 70450], and it's believed to mark the
  mail read [Unverified]. Read mail without it: header, invoice and attachment reads leave unread mail unread
  [F-130].
- Expired and cancelled auctions come back as plain mail (not invoices) with the items attached. Their subjects
  are `AUCTION_EXPIRED_MAIL_SUBJECT` ("Auction expired: %s") and `AUCTION_REMOVED_MAIL_SUBJECT` ("Auction
  canceled: %s"); both exist on Forever, from "Horde Auction House" for a Horde character [F-130]. These global
  strings aren't in the index, so access them as `_G[name]`. Also require `canReply` false and not `isGM`, or a
  player's mail with that subject would count.
- **Mail has no ID.** Count each mail once by a key (kind, item, amount) plus its expiry time,
  `GetServerTime() + daysLeft × 86400`. Give identical mails one stored time each. Key returned items without
  their count: taking some of the items changes the count.
  - **`daysLeft` is a snapshot** of the last inbox refresh, and `CheckInbox` is rate-limited
    (`C_Mail.CanCheckInbox`), so a reopened mailbox can show the old list. The computed time then moves: by up to
    142 s on 70425 [F-130].
  - Match a mail first on its exact `daysLeft` float (the same snapshot), then on the nearest time within a
    tolerance. Store both, and persist them.
- Read on `MAIL_SHOW` and every `MAIL_INBOX_UPDATE` while the mailbox is open, not debounced, so "Open All" can't
  take a mail before it's read.
- Your auctions: `C_AuctionHouse.QueryOwnedAuctions(sorts)` → `OWNED_AUCTIONS_UPDATED` → `GetOwnedAuctions()` →
  `{ auctionID, itemKey, itemLink, status (Enum.AuctionStatus Active 0, Sold 1), quantity, timeLeftSeconds,
  bidAmount, buyoutAmount }`. Blizzard sends that query when its Auctions tab opens. The item link's name is how
  a sales invoice (name only) finds its itemID. For commodities `buyoutAmount` is the **unit** price [F-131].
  - Re-query after `AUCTION_HOUSE_AUCTION_CREATED` and `AUCTION_CANCELED`.
  - Send every AH message through one throttle queue (BuffettForever `Search.WhenReady`).
- BuffettForever: `Pricing/Mail.lua` (reading, `Mail.Reconcile`), `Pricing/Ledger.lua` (filing, sale chance,
  measured cut), `Pricing/Owned.lua`.
- `Constants.AuctionConstants.DEFAULT_AUCTION_PRICE_MULTIPLIER = 1.5` is Blizzard's default price (vendor x 1.5).

## Collecting AH mail (from a click)
Proven on 70450 from a button's click [F-134]:
- **Taking:** `TakeInboxItem(mailIndex, attachmentIndex)`, as Blizzard's attachment click does.
  - `MAIL_SUCCESS` follows 0.2–0.4 s later, **with no item ID**; `MAIL_FAILED(itemID)` means a full bag or a
    unique item.
  - `AutoLootMailItem(index)` (Shift-click on an inbox row) takes a whole mail.
  - Leave COD and GM mail alone, as Blizzard's Open All does.
- **Won-auction mail** is a `"buyer"` invoice, or the `AUCTION_WON_MAIL_SUBJECT` subject on system mail (not
  `canReply`, not returned, not from a GM). One purchase came as one mail [F-134].
- **Blizzard's Open All** (`InboxFrame.OpenAllMail`, `MailFrame.lua` 1515–1712) [Source 70450]:
  - it takes the money first, then each attachment from slot 16 down;
  - it skips GM and COD mail, and stops at 0 free bag slots (`C_Container.CalculateTotalNumberOfFreeBagSlots`);
  - every take after the first runs from `OnUpdate`, after 0.15 s and `not C_Mail.IsCommandPending()`;
  - `MAIL_INBOX_UPDATE` restarts it at mail 1 when the count changes, and `MAIL_FAILED(itemID)` skips that item;
  - its button is disabled only while it runs.
  An addon's takes from a timer are untested on Forever, and a silent block's counter clears only on a restart
  [F-050]. Take one attachment per click.
- **Knowing what left the mailbox:**
  - The inbox reads empty at `MAIL_SHOW`: the list comes with the first `MAIL_INBOX_UPDATE` [F-134].
  - A reopened mailbox can show an old list [F-130].
  - So never take the first read of a visit to mean a mail is gone. A drop in an item's units between two reads in
    one visit is a take, whatever took it: your button, Open All, or Blizzard's click.
- Working code: BuffettForever `Pricing\Collect.lua` (`Collect.MailDrop`, `Collect.Plan`, `/bf mailtest`) and
  `UI\MailButton.lua` (the button: parented to `InboxFrame`, so it shows on the Inbox tab only, and anchored under
  `MailFrame`'s BOTTOMRIGHT, right of the tabs).

## Storing prices in SavedVariables
- **Key by market.** The AH is per ruleset [F-081]. Put the key in one function (realm and faction until the
  probes show what's shared) so it can change in one place, and keep Hardcore separate
  (`C_GameRules.IsHardcoreActive()`). Never key on character name-realm [F-080].
- **Store aggregates, not listings.** Per item and day: market value, min buyout, quantity, auction count. Keep the
  latest price ladder (up to ~8 price levels with quantities) for depth-aware costs. Prune at login (14–30 days).
  The estimators are in the `wowf-economics` skill.
- **Pack it.** A day number (`math.floor(GetServerTime() / 86400)`) and one string per item-day (`"mv:min:qty:n:k"`,
  k = scans that day) keep the file small. SavedVariables load at login and save at logout or `/reload`; huge files
  slow both.
- Measured on 70425: about 185 bytes per item row, plus about 33 bytes per extra day. 3,000 items × 14 days is
  about 2 MB per market [F-127].
- Format numbers with `%.0f`, not `%d`: troll listings reach 10^11 copper, past `%d`'s 32-bit range.
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
Better than `/run` lines: let the addon answer its own probes. Keep a `diag` table in SavedVariables and read it
with `savedvars.py <Addon> --path <DB>.diag` after a `/reload`. BuffettForever's `Pricing\Scanner.lua` records the
index base, every request (cooldown), timings, rows missing info, the realm keys and commodity status.
- Presence: `/run print(type(C_AuctionHouse and C_AuctionHouse.ReplicateItems), type(QueryAuctionItems))` → `function nil`.
- Replicate index base (at the AH, after `/run C_AuctionHouse.ReplicateItems()` and the update event):
  `/run local n=C_AuctionHouse.GetNumReplicateItems() print(n,C_AuctionHouse.GetReplicateItemLink(0),C_AuctionHouse.GetReplicateItemLink(n))`
  → 70425: index 0 is a real row and index n returns `itemID 0`, so the index is 0-based.
- Are reagents commodities? (Linen Cloth; run twice if it prints nil):
  `/run local i=C_AuctionHouse.GetItemKeyInfo(C_AuctionHouse.MakeItemKey(2589)) print(i and i.itemName,i and i.isCommodity)`
  → 70425: true for 2589, 2770, 2840, 2447 and 2318.
- Cut rate (after a sale, mailbox open):
  `/run for i=1,GetInboxNumItems() do local t,n,_,bid,_,dep,cut=GetInboxInvoiceInfo(i) if t=="seller" and bid and bid>0 then print(n,bid,dep,cut,format("%.2f%%",cut*100/bid)) end end`
- AH mail subjects: `/run print(AUCTION_EXPIRED_MAIL_SUBJECT, AUCTION_REMOVED_MAIL_SUBJECT, AUCTION_SOLD_MAIL_SUBJECT)`
- Deposit duration: `/run print(C_CVar.GetCVar("auctionHouseDurationDropdown"), AUCTION_DURATION_ONE, AUCTION_DURATION_TWO, AUCTION_DURATION_THREE)`
- Pricing rules: `/run print(C_AuctionHouse.SupportsCopperValues(),C_AuctionHouse.IsThrottledMessageSystemReady())`
  → 70425: copper values true.
- Market keys: `/run print(GetRealmName(),GetNormalizedRealmName(),UnitFactionGroup("player"))`; compare listings
  seen by an Alliance and a Horde character, and across realms of one ruleset. 70425 values: [F-083]; sharing is
  still open.
- Full-scan cooldown: call `ReplicateItems` twice a few minutes apart and note whether the second returns data.
  → 70425: nothing 877 s after the last data, data 1,120 s after it, so the cooldown is between 14.6 and 18.7 min
  (retail: 15 min) [F-121]. A request log that narrows the bounds (BuffettForever `diag.cooldown`) settles it
  without extra effort.
