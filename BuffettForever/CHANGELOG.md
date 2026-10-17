# Changelog

## 0.8.0 (not released)
- **Settings** in Options > AddOns > BuffettForever (or `/bf options`, or right-click the minimap button).
  Changing one re-ranks the list.
  - Recommendations: margin of safety (20%), minimum profit per craft (10s), lowest confidence grade (C).
  - Costs:
    - the materials you own, counted at what they'd sell for, at nothing, or at what replacing them costs;
    - the house cut (5% until your sales measure it, or always your figure);
    - the sale chance until your sales measure it (50%);
    - the auction length deposits are figured for (what the Auction House remembers, or 2, 8 or 24 hours).
  - Price data: days of history kept (14; fewer deletes the older days at your next login).
- An **Options** tab after the view tabs opens the settings.
- The details pane's Deposit row marks the 1s minimum "(min)": it's the same at every auction length.
- `/bf selftest`: 111 checks (the measured or fixed cut, a fixed auction length, every default a choice the
  panel offers).
- Tested on client 1.60.1.70425, 2026-10-17: selftest 111/111. The panel, its tooltips, live re-ranking and the cut
  work, and the settings are kept. The auction length is to check again on a dearer item: the cloak tried pays
  the 1s minimum at every length. Then the Options tab and the "(min)" mark worked.

## 0.7.0 (not released)
- **Three views** in the middle pane: Tray, Vendor crafts and AH flips, picked with Blizzard's tabs under the
  window (as on the Auction House); the pane's heading names the view.
- **Vendor crafts:** every recipe you know that profits on vendor prices alone.
  - Its reagents come from a vendor, or from your bags counted at what a vendor pays for them; the result goes to
    a vendor. Certain profit, no Auction House risk.
  - The batch is what your bags allow (a vendor's goods don't limit it).
  - Orange when the reagents you own would fetch more on the AH raw; the details pane shows how much.
- **AH flips:** every full scan notes the listings priced below what a vendor pays (your own left out).
  - Buy them on the Auction House, sell them to a vendor: the list shows how many, what they cost, what a vendor
    pays and the profit.
  - The confidence follows the scan's age (A under 15 min, B under 1 h, C under 6 h), since listings vanish fast.
  - Buying stays your click.
  - Items whose vendor price the game hadn't loaded during the scan are checked again once it has (1,309 of
    2,927 items the first time).
- **Details pane icons, as in the profession window:** the result's round icon with its count and its name in its
  quality colour; each reagent in a slot with "have/need Name" (grey when you have too few) and where the rest
  comes from. Hover an icon for the item, Shift-click to link it.
- The Top pick follows the view. `/bf diag` reports the flips of the last scan.
- `/bf selftest`: 107 checks (flips, the vendor-only context, the vendor batch, raw materials on the AH; 35
  scenarios from the Python reference).
- Tested on client 1.60.1.70425, 2026-10-17: selftest 107/107; the three views, the vendor-craft details and a full
  scan's flips work. The tabs then moved from the top of the pane to under the window, where WoW players look
  for them. Then the details pane icons worked, and a scan found 13 flips, loaded the 1,305 items it couldn't price
  at first, and found 5 more.

## 0.6.0 (not released)
- **Your own auctions aren't the market:** full scans leave out the auctions you have listed (from your auctions
  list read at this visit), and searches leave out yours too, so your own listings don't count as depth, set the
  price you compete with, or look like demand. Alt+Right-click says how many of yours it left out.
- **Walls that never shrink:** when a result's cheapest price has held (within 1%) for 3 days while the quantity
  listed never fell, nobody seems to buy at that price. Selling it there gets confidence D (not recommended) until
  you've sold some yourself. The Listed row turns orange and says so.
- **Best batch:** the smaller of what the reagents support and what the market takes, and which one set it
  ("23 crafts (market)", "10 crafts (reagents)"); orange when your batch is bigger, green when it could be bigger.
  - Reagents: the batch with the most profit, searched up to 200 crafts. Past it, each extra craft buys reagents
    higher up the price ladder than it's worth.
  - Market: a quarter of what's listed (at least 1); selling more at once risks flooding the market.
  - The tooltip gives both limits.
- **Mr. Market:** once an item has 5 days of prices, a reagent bought on the AH or a result sold there that's at
  least a standard deviation and 10% away from its fair value shows as cheap or dear, with the advice in the
  tooltip.
- `/bf selftest`: 99 checks, with 5 more scenarios from the Python reference (34).
- Tested on client 1.60.1.70425, 2026-10-17: selftest 98/98; your 2 listed units were left out of a full scan and
  a search; `econ check` matched all 188 recipes and the ranking. Best batch and market cap showed the same
  number for 90 of 155 recipes because the batch search stopped at the cap; they're now independent limits in one
  row.

## 0.5.0 (not released)
- **Sales ledger:** opening a mailbox reads your Auction House mail without opening any of it: what sold (units,
  sale total, the house cut), what expired or was cancelled (the items that came back) and what you bought. Each
  mail counts once, however often the mailbox is opened. Your characters on the same realm and faction share it.
- **Measured house cut:** after 3 of your sales totalling at least 1g, the cut measured from your invoices replaces
  the 5% default.
- **Sale chance per item:** units sold ÷ (sold + expired) from your own auctions, pulled toward your rate over all
  items (which starts at 50%) so a couple of sales don't read as 100%. Cancelled auctions don't count.
- **Deposits:** measured at the auctioneer for your bag items and the outputs of the tray's recipes, for the
  duration Blizzard's sell frame uses. Items never measured get an estimate from what a vendor pays.
- **Your auctions:** read when the Auction House opens and after each post or cancel: what you have listed.
- **An honest AH exit:** price after the cut, minus the deposits expected to be lost on listings that don't sell,
  using each item's own deposit and sale chance. A listing that would lose more in deposits than it earns is worth
  nothing on the AH.
- The details pane says where each number comes from: the cut (measured or the default), the deposit (measured or
  estimated), the sale chance (from your sales or your overall rate), your average sale and what you have listed.
- Alt+Right-click at the Auction House also prints the item's deposit.
- `/bf ledger`: the cut, your sell-through and the items with the most results. `/bf diag` reports mail, deposits and
  your auctions.
- `/bf selftest` also checks the sale chance, the measured cut, mail counting, ledger filing and the deposit
  estimate, and replays 6 more scenarios from the Python reference (26).
- Pass 1 tested on client 1.60.1.70425, 2026-10-17: selftest 74/74; deposits and your auctions are read at the
  Auction House; a cancelled auction is filed once however often the mailbox is opened; unread mail stays unread.
- From the pass 1 diagnostics:
  - **Deposits by Forever's own formula:** 5% of the vendor price per 2 hours (2, 8 or 24 hours), and **at least
    1s per auction**. It matched the game on all 60 measurements. Posting 2 Coarse Thread at 19c each risks a 1s
    deposit, so the evaluator now counts the deposit for the whole batch posted as one auction (gear: one auction
    each). Cheap outputs in small batches now go to the vendor when the deposit outweighs the price.
  - The details pane shows the deposit for the batch, says when it's the 1s minimum, and says when the deposits
    would outweigh the price.
  - Alt+Right-click at the AH prints the deposit for one and for all you carry.
  - Mail counting survives the inbox list the game caches between refreshes (a mail's "days left" doesn't change
    until the inbox refreshes), so reopening the mailbox later can't count a mail twice.
  - The first auctions seen stay in the diagnostics (to settle whether a stack's buyout is per unit).
  - `/bf selftest`: 83 checks, with 3 new scenarios for the deposit rule (29).
  - Tested on client 1.60.1.70425, 2026-10-17: selftest 83/83; Alt+Right-click prints the deposit for one and for
    all; an auction's buyout is per unit for commodities.
- **The details pane is data, not prose:** each number is a label/value row (Cost; Vendor, AH, with its price,
  cut, deposit and sale chance; Listed; Yours; Sell to, Profit, ROI, Value added, Confidence), and its tooltip says
  where the number comes from. The verdict is one line.

## 0.4.0 (not released)
- **Reagent tray:**
  - Drag up to 10 reagents onto the slots, or Alt+Right-click them in your bags (at the AH it also price-checks).
  - Right-click removes; the mouse wheel sets the quantity (Shift: 10). A new reagent starts at what you own.
  - "Load from bags" fills the tray with your reagents, those your known recipes use first. "Clear" empties it.
  - The tray is saved per character.
- **Crafting evaluator:**
  - Each recipe that uses the tray's reagents is evaluated for the crafts your quantities allow.
  - Reagents you own count at what they'd sell for; the rest come from the cheapest of vendor, AH or a recipe you
    know (up to 3 levels deep).
  - The result can go to a vendor or the AH (after the 5% cut). The AH is chosen only when it beats the vendor by
    the 20% margin of safety.
  - Each recipe gets a profit, an ROI, the value added over selling the materials raw, and a confidence grade A–D.
  - A recipe is recommended only at ROI ≥ 20%, profit ≥ 10s per craft and grade ≥ C.
- `/bf eval`: the tray's five best recipes and the top pick in chat (the window panes come next).
- `/bf selftest` runs every test vector in the economics references (29 checks).
- Vendor sell prices for all 2,006 recipe items ship with the data, so no item-cache wait.
- Pass 1 (engine and tray) tested on client 1.60.1.70425, 2026-10-16: selftest 29/29; the tray (drag, Alt+Right-click,
  load from bags, clear) works and is saved per character; `/bf eval` output looked right, and a cross-check
  against an independent implementation follows.
- Validation:
  - `/bf selftest` also replays 20 branch scenarios whose results come from an independent Python implementation of
    the economics (`Economics/EvaluatorVectors.lua`, generated by `cli.py econ vectors`): 49 checks.
  - `/bf eval` saves what it saw and decided, so `cli.py econ check` can replay every recipe in Python. On 70425 all
    143 recipes and the ranking matched.
- **The vendor cap:** an item a vendor sells is never worth more than the vendor's price, whether you own it or sell
  it (Coarse Thread listed at 19c costs 10c at a vendor).
- **Craftable items list:**
  - every recipe for your tray, with the units it makes (* = you know it), cost, best exit (AH or V = vendor),
    profit, ROI and confidence grade;
  - click a heading to sort, a row for its details;
  - losses red, the not-recommended grey;
  - "Known only" and "Show unconfirmed" filters.
- **Top pick:** the advice for the best recommended recipe, plus the most gold per batch when that's a different
  recipe.
- **Details pane:**
  - every reagent with its source (owned, Vendor, AH, Craft) and cost;
  - the vendor and AH exits, with the market depth behind the AH price and a warning when every listing is at one
    price;
  - profit, ROI, value added, the grade, and the verdict with its reasons.
- The window is 1,040 px wide, to fit the columns. `/bf selftest` saves its result in the diagnostics.
- Pass 2 (panes) tested on client 1.60.1.70425, 2026-10-16: selftest 49/49, list, sorting, details, filters and
  updates work; `econ check` matched 91 of 91 recipes and the vendor cap held.
- From the pass 2 review:
  - The tray holds **25 reagents** (5 × 5); the window is 600 px tall.
  - "Most gold" has its own heading under the top pick.
  - The Grade column is wider. Its heading's tooltip explains how grades work, and the details pane says which price
    set the grade and why (e.g. "Light Leather has 1 day of data").
  - The details pane scrolls, with space around each section heading.
  - **Vendor goods count as always available:**
    - recipes made entirely from vendor-sold reagents are listed (marked v) even with nothing in the tray;
    - a vendor-sold reagent in the tray no longer caps the batch size.
  - Tested on client 1.60.1.70425, 2026-10-16: selftest 50/50, all seven checks pass, and `econ check` matched 92
    of 92 recipes with the vendor cap holding.

## 0.3.0 (not released)
- Recipe data: 1,976 Forever recipes from the 1.60.1.70450 game tables (`Data/Recipes.lua`, IDs and numbers only),
  each with its profession, skill-up colors, output and reagents. Recipes added after Classic (860: Forever-new and
  Season-of-Discovery IDs) are flagged unconfirmed until seen in game; outputs seen on the AH count as seen.
- Vendor prices for the 26 reagents confirmed on sale at a vendor (`Data/Vendor.lua`). A price harvested at a
  merchant wins over them, and tooltips show "Vendor sells it for" for these reagents.
- `/bf recipes <item link or ID>`: the recipes that use or make an item.
- `/bf selftest` also checks the recipe data.
- Pass 1 (recipe data and lookup) tested on client 1.60.1.70425 with the 70450 data, 2026-10-16: selftest 14/14.
- Known recipes: opening one of your professions records every recipe the character knows (per character, by full
  name), and every recipe the window lists counts as confirmed on Forever. `/bf recipes` marks known recipes.
- `/bf diag` also reports what the profession window gave: how many recipes, known ones missing from the data,
  whether yields and reagents match, and whether recipes can be checked without opening the window.
- Pass 2 (known recipes) tested on client 1.60.1.70425, 2026-10-16: Leatherworking harvested (6 known of 592 listed),
  yields and reagents match the data, and IsSpellKnown agrees with "learned" on all 592.
- From the pass 2 diagnostics:
  - **Known recipes are read at login** from the spellbook, so no profession window needs opening. A dropped
    profession drops its recipes.
  - A recipe listed by a profession window no longer counts as confirmed (the window lists Season-of-Discovery
    recipes too). The saved list of them is removed (data version 2).
  - `/bf recipes` lists the recipes you know first, then other confirmed ones, then unconfirmed new ones, with counts
    in its first line. `/bf recipes <item> all` lists every recipe, not just the first 20.

## 0.2.0 (not released)
- Full Auction House scan (`ReplicateItems`), time-sliced so the game never freezes. Start it with the Scan
  button in the window, the Scan button under Blizzard's Auction House frame, or `/bf scan`. Progress shows in
  the window's status line. Closing the AH stops a scan; an empty AH, bid-only listings and a scan that gets no
  data (60 s timeout) each say so.
- Prices per market (realm, faction, Hardcore apart) for every item: market value (lower-quantile trimmed
  mean), min buyout, quantity, auction count, the latest price ladder and a packed daily history, pruned at login
  to 14 days.
- Read-only guard for `SAVED_VARIABLES_TOO_LARGE`: scanning pauses and the player is told.
- `/bf diag`: scanner diagnostics (index base, request cooldown, timings, rows missing info, market-key inputs,
  copper values, which reagents are commodities). `/bf selftest`: the price math against its test vectors.
- Pass 1 (full scan and storage) tested on build 1.60.1.70425, 2026-10-16: 61,933 listings, 2,998 items, 5.5 s.
- **Alt+Right-click** an item: at the Auction House it searches the item's current listings and prints market
  value, min buyout and quantity (and stores them); anywhere else it prints the stored prices and their age.
  Plain clicks are unchanged.
- Targeted searches: a queue with one query in flight that waits for the AH throttle and never runs during a full
  scan. Commodities, plain items and equipment (all item levels) are each searched the way Blizzard's sell frame does
  it, reading up to 5 pages.
- Vendor buy prices are recorded while a merchant window is open (unit price, and stock when limited).
- Tooltip lines: AH market value with its age, AH min buyout, what a vendor pays, and what a vendor charges.
- The status line and Scan tooltips say when the next full scan is likely to get data; the cooldown is measured from
  the request log (over 2 min on 70425).
- Fixes: row `n` of a full scan (itemID 0) no longer counts as a listing, so the index base reads 0. A scan stopped
  while waiting now records how long it waited.
- Pass 2 (searches, bags, merchant, tooltips) tested on build 1.60.1.70425, 2026-10-16.
- From the pass 2 diagnostics:
  - A commodity search no longer overwrites the auction count: its rows are grouped by price, so it reports "listed at
    N prices" and keeps the full scan's count.
  - The next-scan hint keeps retail's 15 min inside the measured cooldown bounds instead of jumping to the upper
    bound (38 min).

## 0.1.0 (not released)
- Scaffolded with the workspace generator: window (layout only: reagent tray, top pick, craftable items,
  details, status line), coin icon, minimap button, addon compartment entry, `/bf` and `/buffett`, Settings panel.
- Tested on build: 1.60.1.70425 (beta), 2026-10-16
