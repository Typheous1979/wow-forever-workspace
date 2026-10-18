# BuffettForever — addon notes

Addon-only context for Igor. The workspace CLAUDE.md, the wowf skills and the shared memory load from the
parent folders (the workspace root is `..`), so this file holds only what is specific to BuffettForever.
Not shipped (package.py leaves CLAUDE.md out). Skills to load for this addon: `wowf-addon-dev` (read
auction-house.md and professions-and-vendors.md) and `wowf-economics`.

## Purpose
Scan the Auction House, keep prices for every item, and advise on crafting. The player drops up to 25 reagents
into a tray; BuffettForever lists every recipe that uses them, prices each recipe's inputs (vendor, AH, craft or
owned) and outputs (vendor or AH), shows ROI %, and recommends what to craft and where to sell it. Named for
Buffett's rules: never lose money, margin of safety, Mr. Market, opportunity cost.

## Status
- 0.1.0 (2026-10-16): scaffold + raw window (layout only), coin icon, minimap button, compartment, `/bf` and
  `/buffett`, Settings panel (minimap toggle). Lints clean. Tested in game on 1.60.1.70425: works.
- 0.2.0 M1 pass 1 (2026-10-16): full scan (Scanner), PriceDB, Econ.MarketValue/BuildLadder, diagnostics, Scan
  buttons in the window and under the AH frame, `/bf scan | diag | selftest`. Tested on 70425: 61,933 listings,
  2,998 items in 5.5 s; selftest 6/6; abort on AH close and the cooldown timeout work.
- 0.2.0 M1 pass 2 (2026-10-16): Search queue, Bags (Alt+Right-click), Merchant, Tooltip, cooldown hint, index-n
  fix. Tested on 70425: all eight checks pass. Commodity searches answer in about 0.1 s in one page; equipment
  searches (all item levels) in about 0.3 s. M1 complete.
- 0.3.0 M2 pass 1 (2026-10-16): `recipe-catalog` tool (committed), Data/Recipes.lua (1,976 recipes, 70450),
  Data/Vendor.lua (26), Util/Items.lua, Crafting/RecipeIndex.lua, `/bf recipes`, recipe selftests. Tested on client
  70425 with the 70450 data: selftest 14/14, `/bf recipes` lookups, vendor-seed tooltips, no load-time cost.
- 0.3.0 M2 pass 2 (2026-10-16): Crafting/Harvest.lua (recipesKnown per "First Surname", recipesSeen, probes in
  diag.harvest). Tested on 70425 (Leatherworking 49/75). The probes showed GetAllRecipeIDs lists the whole skill line,
  Season-of-Discovery recipes included, so "listed" can't confirm a recipe.
- 0.3.0 M2 follow-up (2026-10-16): known recipes read at login with IsSpellKnown (13 found, 0 ms), recipesSeen
  dropped (migration 1 → 2), `/bf recipes` ordered known → confirmed → unconfirmed, with `all`. Tested on 70425.
  **M2 complete.** M3 (tray, evaluator, panes) next.
- 0.4.0 M3 pass 1 (2026-10-16): Econ (CostToBuy, FairValue, AHNet, Liquidation, ROI, Acquire, Volatility, Grade),
  Economics/Evaluator.lua (pure Evaluate over a context; LiveContext; ForTray; Advice), Crafting/Tray.lua,
  UI/ReagentTray.lua, Bags → tray, `/bf eval`, 29 selftests, ns.ItemSellPrice in the data. Tested on 70425:
  selftest 29/29, tray works and persists. Justin asked for richer validation than eyeballing `/bf eval`, so a
  Python reference evaluator cross-checks the Lua.
- 0.4.0 validation (2026-10-16): `tools/wowf/econ.py` (committed), Economics/EvaluatorVectors.lua (20 scenarios
  replayed by the selftest), the `/bf eval` snapshot in diag.eval. `econ check` on 70425: 143 of 143 recipes and the
  ranking match.
- 0.4.0 M3 pass 2 (2026-10-16): UI/ResultsList.lua, UI/DetailPanel.lua, top pick, vendor cap, diag.selftest,
  window 1,040 px. Tested on 70425: selftest 49/49, everything works; `econ check` 91/91, cap holds.
- 0.4.0 M3 pass 2 review (2026-10-16): 25-slot tray, window 600 px tall, "Most gold" heading, Grade column and
  explanations (Econ.Grade returns the deciding test; r.gradeWhy), scrolling details with section spacing,
  vendor goods always available. Tested on 70425: selftest 50/50, `econ check` 92/92. **M3 complete.**
- 0.5.0 M4 pass 1 (2026-10-16): an honest AH exit. Pricing/Ledger.lua (sales ledger per market, measured cut,
  sale chance), Pricing/Mail.lua (inbox reader, Mail.Reconcile), Pricing/Deposits.lua (measured at the AH,
  deposit/vendor fit), Pricing/Owned.lua (your auctions), Search.WhenReady shared by every AH message, evaluator
  with per-item deposit and sale chance (AH net floored at 0), details-pane sources, `/bf ledger`. Python
  reference: sale_chance, measured_cut, 26 scenarios. Tested on 70425 (2026-10-17): selftest 74/74; deposits
  and your auctions read at the AH; a cancelled auction filed once however often the mailbox opens; unread mail
  stays unread. Still to check: the details pane's sources, and a real sale.
- 0.5.0 pass 1 follow-up (2026-10-17): deposits by Forever's formula per auction [F-129] (migration 2 → 3),
  mail matched on the exact days-left first [F-130], your auctions' samples kept. Tested on 70425: selftest 83/83,
  Alt+Right-click prints the deposit for one and for all, owned buyout is per unit [F-131]. Then the details pane
  became label/value rows with tooltips (Justin: data, not paragraphs): to check in game.
- 0.6.0 M4 pass 2 (2026-10-17, built, not yet tested in game): market reality. Your own auctions left out of
  scans (Ledger.OwnLevels + Econ.ExcludeOwn) and searches (numOwnerItems, containsOwnerItem); stale walls grade D
  on the sell side (Econ.StaleRun, priceInfo.stale/sold); Evaluator.BatchAdvice (best batch, market cap);
  Mr. Market moods (Econ.MrMarket, Econ.Mood) in the details pane. Python reference: stale_run, mr_market, mood,
  exclude_own, batch_advice; 33 scenarios. Tested on 70425 (2026-10-17): selftest 98/98, your 2 units left out of
  a scan and a search, `econ check` 188/188. Justin saw best batch equal the market cap most of the time (90 of
  155): the search stopped at the cap. Reworked into one row from two independent limits (reagents up to 200
  crafts, market a quarter of what's listed; BATCH-VENDOR added, 34 scenarios): to check in game.
- 0.6.0 committed after Justin's check of the reworked best batch (2026-10-17): selftest 99/99.
- 0.7.0 M4 pass 3 (2026-10-17): scanners as views (Tray | Vendor crafts | AH flips)
  in UI/ResultsList.lua; Evaluator.VendorContext/VendorBatch/VendorCraft/VendorCrafts (rawAH, rawBetter);
  Pricing/Flips.lua (Flips.Find during each full scan, Flips.Results, Flips.Advice; markets[key].flips);
  Econ.Flip; RecipeIndex.Known; the details pane's flip layout and vendor-craft rows. Python reference: flip,
  vendor_context, VENDOR-CRAFT (35 scenarios). Tested on 70425 (2026-10-17): selftest 107/107, the three views,
  the vendor-craft details and a scan's flips work. **M4 complete** (profit per hour and the value-added column
  wait for M5, as decided).
- 0.7.0 follow-up (2026-10-17): the view tabs moved from the top of the middle pane to Blizzard's
  bottom tabs under the window (PanelTabButtonTemplate, as on the Auction House); the heading names the view again.
  Tested on 70425: the tabs work and stay on screen. The logged mail tests passed: 2 Light Leather expired and were
  filed once, a mailbox reopened about 4 minutes later filed nothing twice, and a 19c Coarse Thread sale was filed
  with no cut. The first flips scan found 6, but 1,309 of 2,927 items' vendor prices weren't cached yet.
- 0.7.0 second follow-up (2026-10-17): the details pane shows items as the profession window
  does: a round result icon with the count and the quality-coloured name, and reagent slots with "have/need Name"
  (Justin's request). Flips.Recheck loads the items whose vendor price wasn't cached during a scan and looks again.
  Tested on 70425: the icons work; a scan found 13 flips, then loaded all 1,305 unpriced items and found 5 more.
- 0.8.0 M5 pass 1 (2026-10-17): Options.lua puts every economics setting in
  Blizzard's panel, plus two new ones: measuredCut (use the cut your sales measure, default on) and
  depositDuration (0 = what the AH remembers). SETTINGS_CHANGED re-ranks the list. Ledger.Cut(book, settings)
  and Deposits.Duration(settings) take test inputs; Options.SelfTest checks the defaults; selftest 111.
  Tested on 70425: selftest 111/111; the panel, live re-ranking and the cut work, and the settings are kept. Justin
  saw Embossed Leather Cloak's deposit stay 1s at every length. That's correct: a vendor pays 112c for it, so
  the formula gives 5c, 20c and 60c, all under the 1s minimum. 105 of the 168 recipes in his last snapshot
  do change with the length.
- 0.8.0 follow-up (2026-10-17): an Options tab after the view tabs opens Blizzard's settings
  window at our page and lowers our window under it (Justin: fewer slash commands). The Deposit row marks the
  1s minimum "(min)". Tested on 70425: both work. Still to see in game: a deposit changing with the auction
  length (Alt+Right-click a stack in the bags prints it for the length in use).
- 1.0.0 M5 pass 2 (2026-10-17, in progress): the README rewritten for 1.0.0, the CurseForge page
  (docs/BuffettForever-curseforge.md), version 1.0.0, and dist/BuffettForever-1.0.0.zip (37 files, 152 KB; the
  logo is dist/BuffettForever-logo-512.png). Next: Justin reviews the page, takes the screenshots and uploads it
  as Beta; then a check on the stress-test client (`_forever_`, from Oct 19).
- 1.0.0 search (2026-10-17; Justin: the list gets long): Blizzard's SearchBoxTemplate right of the list's
  heading filters every view by item name on each keystroke (Words, Matches, Shown in UI/ResultsList.lua; rows only,
  no re-evaluation). ShowRows keeps the selection while it's shown, else selects the best-ranked row shown; a new
  search scrolls to the top; the count line reads "4 of 168 shown". SEARCH-MATCH in the selftest (112). Tested on
  70450 (Justin's client updated): selftest 112/112, filtering as you type, any word order, the no-match message and
  the empty details, the search kept across tabs and a reopen, the X, and Escape twice. The zip was rebuilt with it.
- 1.0.0 Profession profits pass 1 (2026-10-17; the plan is in the decisions below):
  - VIEWS "professions" with Evaluator.ForProfessions on TrayContext (owned = the tray's units only) and TrayCrafts
    (shared with ForTray);
  - Harvest.Professions (GetProfessions slots, then known recipes' lines), Rank, Difficulty (GetRecipeInfo's
    relativeDifficulty, else RecipeIndex.Difficulty from the thresholds), DifficultyColor;
  - groups as header elements (ListHeaderVisualTemplate, SetElementFactory) in the linear list, GroupElements;
    per-view filter prefs (results.professions);
  - the Skill-up row and tray-only slot tooltips in DetailPanel; Show keeps the scroll for the same recipe and view;
  - the hidden purchase probe `/bf buytest` (Pricing/Buy.lua, diag.purchases);
  - diag.harvest.professions (raw slots, Blizzard's difficulty against the thresholds', the evaluation time);
  - selftest 117.

  Tested on 70450: selftest 117/117; the tab, its groups (collapsed state kept over a /reload), the filters and the
  skill-up colours (the profession window's, checked on 3 recipes) work; tray-only slots work. Blizzard's difficulty
  matched the thresholds' on the 6 Leatherworking recipes; the other professions' recipes all read optimal, which
  pass 2's diagnostics explained [F-133]. 399 recipes evaluate in 21 ms (42 ms at worst), so no
  splitting across frames. `/bf buytest 2589 1` then `confirm` bought 1 Linen Cloth for 19c, delivered by mail
  [F-132]. Justin found the "Craft" source confusing in this tab, where everything not in the tray is bought.
- 1.0.0 Profession profits pass 2 (2026-10-18):
  - the "Craft" fix: TrayContext buys reagents as listed (recipeFor empty); Evaluator.MakeHint (from makeFor) tells
    the slot's tooltip when a recipe you know makes one for less, or makes one nobody sells; MadeFrom names a
    crafted line's reagents in the other views;
  - UI/BuyBar.lua: the status line over [Best] [- n +] [Buy], in Profession profits only; ResultsList.SetCrafts
    with Evaluator.Reevaluate (craftsFor kept until another recipe or view); Best = Evaluator.AffordableBatch;
    Buy disabled, its tooltip the Evaluator.ShoppingList;
  - live prices: at the AH (window open), the shown recipe's AH reagents with prices over 60 s old are searched,
    each at most once a minute; Search.Finish fires PRICES_CHANGED, which re-evaluates the list;
  - diag.harvest.professions.window (whether the profession window was open for the difficulty readings);
  - selftest 121 (TRAY-BUY, CRAFTS, SHOP-LIST, BEST-GOLD).

  Tested on 70450: selftest 121/121; buying as listed with the gold "Cheaper to make" hint, Crafts (row and details
  follow, reset on another recipe), Best, Buy's tooltip away from and at the AH ("Prices from <1 min ago"), and no
  jump while prices update. The bar searched Light Leather and Ruined Leather Scraps about once a minute while Justin
  clicked around, 70-211 ms each. The window flag showed the bug in Harvest.Difficulty: with the profession window
  closed, GetRecipeInfo's relativeDifficulty read optimal for all 13 known recipes, so the * marks were orange until
  that profession's window opened [F-133]. Fixed in pass 3: the thresholds only.
- 1.0.0 Profession profits pass 3 (2026-10-18): buying the AH reagents. Tested on 70450: selftest 124/124; the
  colours right with no profession window opened; Linen Bandage's Linen Cloth bought (18c), credited, "in your
  mailbox" until collected; Cancel and closing the AH dropped the price with nothing spent; the Camp Chair's two AH
  reagents (Light Leather, Simple Wood) took four clicks. The log has no quote that ran out by itself, and the
  too-little-gold check is still to do (Justin: later). 3 Light Leather quoted 2s 13c cost 1s 50c: 118 were listed
  at 48c by the next search, so the server charged the cheaper listings [F-132]. Simple Wood cost 1s 20c each on the
  AH; a trade-goods vendor sells it in Classic for about 38c, but the vendor data has no evidence for it yet.
  - Pricing/Buy.lua replaces the probe with the purchase states (ready, quoting, confirm, buying): Buy.Start and
    Buy.Confirm run inside the clicks; QuoteCheck (Blizzard's 5% rule against a search under 2 minutes old, else the
    rise shown); ProfitAt (profit + estimate - quote; the plan had the sign the wrong way round); a 10 s no-answer
    timer; a 0.2 s ticker for the time left and Blizzard's buy dialog taking over; cancel on another recipe or view,
    AH_CLOSED and combat (PLAYER_REGEN_DISABLED, COMBAT_ENDED from Core); skipped lines re-searched; the search-box
    fallback (blocked during a purchase, two quotes unanswered, or not a commodity). `/bf buytest` still probes.
  - Tray.Credit / CreditEntries / HasRoom; charDB.bought with Buy.InMail (until the bags and bank hold it, 30 days at
    most), shown in the slot and Buy tooltips.
  - UI/BuyBar.lua: Buy, then Confirm (Best is Cancel meanwhile); the status line shows the next line, the quote with
    its rise, a loss in red and the last 10 s; ResultsList.Update straight after a purchase, so the next line comes
    up at once; Buy waits for the re-evaluation after a search ("eval" pending).
  - Search: IsBusy, waits while a purchase is open, AH_THROTTLE_READY and SEARCH_DONE.
  - Harvest.Difficulty from the thresholds only; the window harvest compares Blizzard's colours with ours while the
    window is open (colourAgree, colourDisagree, colourSample in diag.harvest[profession]).
  - selftest 124 (QUOTE-CHECK, TRAY-CREDIT, IN-MAIL).
- 1.0.0 the logo and Profession profits pass 4 (2026-10-18): buying vendor reagents and AH flips. Tested on 70450:
  selftest 126/126; the logo; 1 Coarse Thread for Handstitched Leather Cloak bought at a trade-goods vendor (10c,
  `BuyMerchantItem(7, 1)`, in the bags 0.9 s later and credited to the tray); two Cross Daggers bought as a gear flip
  at 38s each (a vendor pays 38s 30c). The second auction came up as soon as the first was bought, and the flip left
  the list once the next search's cheapest was 39s. Both daggers came by mail [F-132]. No stackable flip was bought
  (Justin's flip test was the Cross Dagger; the list's one stackable flip, 65 Lesser Moonstone, made 65c on 3g 89s),
  so a flip's quote and FlipCheck's refusal are still to see in game.
  - the logo in ButtonFrameTemplate's round portrait (SetPortraitToAsset with Media/Icon, as Blizzard's Professions
    window; Justin's request), the status line moved right of it;
  - vendor reagents at a merchant: Merchant.Find (the open merchant's slot per item, checked against
    GetMerchantItemID), Merchant.BuyQty (whole stacks, GetMerchantItemMaxStack, the stock), Buy.StartVendor
    (BuyMerchantItem inside the click; Confirm at 150g, MERCHANT_HIGH_PRICE_COST), the bags' rise credited;
  - AH flips: the bar on the AH flips tab (Buy only); Search keeps gear auctions (auctionID, buyout, qty) and
    SEARCH_DONE carries the result and "empty"; Flips.Update renews or drops a flip from a search; commodity flips
    by quote with Buy.FlipCheck (refused once the units cost what a vendor pays); gear by Buy.StartAuction, then
    Confirm → PlaceBid → AUCTION_HOUSE_PURCHASE_COMPLETED; the item searched again after each purchase;
  - selftest 126 (FLIP-CHECK, VENDOR-QTY).
- 1.0.0 Profession profits pass 5 (2026-10-18): the release docs. The README and the CurseForge page describe the
  tab and the Buy bar, and say "It never buys without your click: each purchase shows its price first. It never
  posts." The CHANGELOG's 1.0.0 entry is complete, with the tests. dist/BuffettForever-1.0.0.zip rebuilt (39 files,
  184 KB). Then Justin asked for a tune-up and one more feature before the upload (below), so the release set
  (TOC version, CHANGELOG, README, the page) waits for those passes.
- 1.0.0 tray, Collect, Craft and Post pass 1 (2026-10-18): the tray tells the truth, Collect, and the probes (the
  plan is in the decisions below). Tested on 70450:
  - selftest 131/131; the envelope, grey icon and mailbox line; Load from bags kept what's in the mail;
  - `/bf mailtest`: the 3 Light Leather bought in one purchase were one mail, one attachment;
  - Collect took it with TakeInboxItem from the click (MAIL_SUCCESS with no item ID 0.2 s later), then the Linen Cloth
    bought for the test, and the envelopes went [F-134];
  - the craft probe: with the window closed CraftRecipe did nothing (3 tries, no event, no error), and before First
    Aid had been opened that session the game said the recipe wasn't learned and 0 craftable; with it open, 1 Linen
    Bandage. OpenRecipe opened the window at the recipe, and StopRecipeRepeat stopped a batch of 2 after 1.
    ReagentsFromBankAllowed is false. Charred Wolf Meat: Cooking Fire not met [F-135];
  - the post probe: PostCommodity posted 1 Light Leather at 74c (the cheapest by others) for a 1s 2-hour deposit,
    needsConfirmation false, AUCTION_CREATED 303 ms later, no warning or popup [F-136].
  So Craft opens the window first (OpenRecipe), then crafts, and Post ships in 1.0.0. Not tested: a gear post, a
  same-item mail bought outside BuffettForever, and taking our mail with Blizzard's own click.
  - Core owns PLAYER_REGEN_DISABLED (COMBAT_STARTED, ns.InCombat), ADDON_ACTION_BLOCKED/FORBIDDEN (diag.blocked,
    ACTION_BLOCKED) and AUCTION_HOUSE_SHOW_ERROR (AH_ERROR); Buy listens on the bus. Owned passes
    AUCTION_CREATED(auctionID) on, Harvest TRADESKILL_CHANGED(event), Mail MAILBOX_OPEN/READ/CLOSED.
  - Pricing/Collect.lua: charDB.bought = { q still in the mailbox, t, k } for every AH purchase (ah, flip, auction),
    recorded before the tray credit; the drop rule (Collect.MailDrop) over Mail.Won's units per item; the old
    `{q, base, t}` entries converted once; Collect.Plan/Pick; the take (TakeInboxItem inside the click, done on
    MAIL_SUCCESS or the bags' rise); `/bf mailtest`; diag.collect.
  - Mail.lua: Mail.Won (won-auction attachments), IsOpen, ReadNow; the units read even with a read-only account
    file; diag.mail.fresh at each open.
  - Tray: BankUsable/UsableCount (Blizzard's reagent rule), BankCount, SlotState, LoadCandidates (Load from bags keeps
    what's in the mail), Add's default counts the mail. UI: the slot's envelope (atlas ui-hud-minimap-mail-icon),
    grey icon and orange count, the four tooltip rows, the mailbox line in the hint's place; UI/MailButton.lua.
  - Probes: Crafting/Craft.lua `/bf crafttest` (facts, CraftRecipe, open, openline, stop; diag.crafts) and
    Pricing/Post.lua `/bf posttest` (facts, the price from a search, confirm, a second confirm after a warning;
    diag.posts).
  - selftest 131 (COLLECT-REMEMBER, MAIL-DROP, MAIL-LEGACY replaces IN-MAIL, COLLECT-PICK, TRAY-SLOT, TRAY-LOAD-MAIL).
- **Tests logged for later** (Justin, 2026-10-17: "in future builds"): the house cut, once 3 sales worth 1g in
  all have come by mail (`/bf ledger` shows the measured cut). From pass 3 (2026-10-18): Buy greyed out with "Not
  enough gold" when Crafts makes the cost more than your gold, and a quote left to run out (the last 10 s counted
  down, then dropped). From pass 4: a stackable flip bought by quote, and a vendor reagent sold in stacks (Mild
  Spices, 5 a purchase) bought for a recipe. From the tray pass 1 (2026-10-18): a gear post, a same-item mail you
  bought yourself (Collect leaves it when it's larger than ours), and our mail taken with Blizzard's own click (the
  envelope should still go). The expiry and mailbox-reopen tests passed on
  70425 (2026-10-17).

## Decisions (2026-10-18, the tray's mailbox, Collect, Craft and Post; Justin's answers, then the approved plan)
- **Justin's questions:** can an AH purchase go straight into the bags, so the tray's units are really there? Can a
  button in the details craft a known recipe from the tray's materials? Can it post at the AH? All go into 1.0.0.
- **The bags: no.** Forever mails every AH purchase [F-132]. Instead the tray shows where its units are (an envelope
  with the units in the mailbox, a grey icon when crafting can't use any, an orange count when you're short) and a
  **Collect button** under Blizzard's mail window takes the mail of what BuffettForever bought, one attachment per
  click, inside the click (Justin chose it over taking mail by itself at the mailbox). Open All still works.
- **The mailbox count** is read from the mailbox: q drops only when an item's units in won-auction mail drop during
  one visit (any way of taking mail counts); the first read of a visit never clears anything (a cached inbox can
  miss new mail [F-130]). The 30-day expiry stays. Gear and flips are recorded too (Collect takes them); the
  Cross Daggers bought before this aren't.
- **Craft and Post get a second row** in the bar under the details (Justin chose it over one button that changes
  with the step): [Best] [- n +] [Buy] over [Craft n] [Post n]. Each button does one thing, greyed with the reason.
- **Craft** (pass 2): in every recipe view, for known recipes, from the bags (and the bank only if
  ReagentsFromBankAllowed). Every finished craft of a recipe in the data (UNIT_SPELLCAST_SUCCEEDED, from either
  window) takes its reagents off the tray and adds the output to charDB.made. The probe decides whether the
  profession window must be open (then the first click opens it with OpenRecipe).
- **Post** (pass 3): at the AH, **at the cheapest listing by others** from a search just before, no undercut
  (Justin's choice; Blizzard's default). Only what you crafted (charDB.made) that's in your bags. Refused when a
  vendor pays more after the cut; a price under half the market value shows in orange. A post the AH asks to
  confirm takes a third click; Blizzard's own warning popup is left alone (hiding it from addon code would taint
  the shared popups), and `AuctionHouseFrame:SetPostItem` is never called. If the probe shows posting is blocked,
  1.0.0 ships without Post and keeps "It never posts".
- **Rules:** one action per click, inside the click; Buy, Craft and Post exclude each other (AUCTION_HOUSE_SHOW_ERROR
  doesn't say which one failed); never drive Blizzard's frames.
- **Passes:** 1. the tray, Collect and the probes; 2. Craft; 3. Post; 4. the release docs.

## Decisions (2026-10-17, the Profession profits tab; Justin's answers, then the approved plan)
- **The tab:** "Profession profits", between AH flips and Options. Every recipe in this character's professions, in
  collapsible groups per profession (Justin chose groups over one list with a dropdown). Known only is on by default.
  It goes into 1.0.0, which isn't uploaded yet ("before we release").
- **Materials: tray only** (Justin; not "owned first"). In this tab only the tray's units count as yours; everything
  else is bought, even what's in the bags or bank. The tooltips say so: the tab, the reagent slots (with the bag and
  bank count), the Cost row, and later the Buy button.
- **Buying:** the live price, then a confirm click, per reagent. The Auction House must be open, and the button's
  tooltip says so.
  - If Forever blocks addon purchases, the button falls back to `AuctionHouseFrame:SetSearchText(name)` (agreed).
  - Each purchase call runs inside the player's click, never through a queue or a timer.
  - Blizzard's 5% rule (a quote more than 5% over the preview is refused) applies only against a fresh search's
    price; against an older scan, the difference is shown.
- **The Buy bar** shows on Profession profits and AH flips only. Bought reagents are credited to the tray, because
  AH purchases arrive by mail [F-132]: the tray-only plan then never offers them twice.
- **Reagents are bought as listed in this tab** (2026-10-18, after Justin's pass 1 test: "Craft may be confusing, maybe
  it should be AH? Open to a better idea"). Each reagent comes from the tray, the AH or a vendor; make-or-buy is off,
  so the Buy bar buys exactly what the slots show. Crafting an intermediate there would mean buying its own reagents,
  which the tray credit can't track: make-or-buy ignores owned stock below the first level, so they'd be offered
  again. A recipe you know that makes a reagent for less (Light Leather from Ruined Leather Scraps), or makes one
  nobody sells, is a hint in the slot's tooltip: make it, then put it in the tray. The Tray and Vendor crafts views
  keep make-or-buy, and their "Craft" tooltip now names the reagents it's made from.
- **Extras** (Justin chose all three): skill-up colours on the * known marker in every view (the row's colour still
  shows profit); buying AH flips (commodities by quote and confirm, gear by PlaceBid on an auction shown first);
  buying vendor reagents at a merchant (BuyMerchantItem, one click per line, a confirm at 150g or more).
- **Passes:**
  1. the grouped tab, tray-only costs, skill and colours, and a hidden purchase probe (`/bf buytest`);
  2. the bar's Crafts box, Best and live prices at the AH;
  3. buying AH reagents;
  4. buying flips and vendor reagents;
  5. the release docs.

## Decisions (2026-10-17, M5; Justin: "Proceed with Pass 1" after the plan and its recommendations)
- **Order:** pass 1 the settings; pass 2 the release (README, CurseForge page, screenshots, 1.0.0, package, then a
  check on the stress-test client, build 70245, once it's installed).
- **Dropped from M4's leftovers:**
  - profit per hour: a craft takes seconds, so the figure would mislead, and the market is the limit, which
    Best batch already shows;
  - a value-added column: the list has no room for a seventh column, and the details pane shows value added.
- **Settings bind to db.settings** through Blizzard's panel. The defaults live in Core.lua only
  (ns.DEFAULT_SETTINGS). Lowering the price history deletes the older days at the next login (PriceDB.Prune), and
  the tooltip says so.
- **Search** (Justin, 2026-10-17: "Proceed with item names only"): the search matches the row's item name only, not
  its reagents' names. Every word must appear, in any order, as plain text. The top pick and Most gold ignore the
  search. The text is kept across views and while the window is closed, but isn't saved (a /reload starts empty).

## Decisions (2026-10-16, M4; Justin approved the plan's recommendations)
- **Order:** pass 1 an honest AH exit (sales ledger, measured cut, deposits, your auctions); pass 2 market reality
  (your own auctions left out of depth, walls that never shrink get grade D, Mr. Market hints, batch-size advice);
  pass 3 scanners (views Tray | Vendor crafts | AH flips). Profit per hour and a value-added column wait for M5.
- **Ledger per market,** shared by your characters there (the mail is per character, the market isn't).
- **The measured cut replaces the setting automatically** (after 3 invoices worth 1g); M5 adds an override.
- **Sale chance** in units, per item, pulled toward your rate over all items (5 pseudo-units), which is pulled
  toward settings.saleChance (2); floor 0.05; cancels don't count. An AH net below 0 counts as 0.
- **Deposits** (revised 2026-10-17 from the pass 1 diagnostics): Forever's formula [F-129], per auction, at the
  duration Blizzard's sell frame remembers (CVar `auctionHouseDurationDropdown`). A batch of a commodity goes up
  as one auction (deposit ÷ units), gear one auction each. Reagents valued for sale use the batch's need. The
  game's own figures are only checked against the formula (diag.deposits), and the check records commodity or
  gear per item.
- **Mail is read without opening it** (never `GetInboxText`); no player names are stored. A mail is identified by
  its key, then its exact days-left (the inbox list is a snapshot [F-130]), then its expiry time within 300 s.
  Returns are keyed without their count.
- **Walls that never shrink get grade D** (pass 2), unless your own sales show the item sells.
- **Scanners are views in the existing list,** not new windows (pass 3).
- **The view tabs sit under the window** (Justin, 2026-10-17: players would miss them at the top of the pane).
  They are Blizzard's bottom text tabs, as on the Auction House, Friends and Merchant windows. Forever's redesigned
  windows (Character, Professions, Collections) use icon side tabs, but an icon hides what "Vendor crafts" and
  "AH flips" mean until you hover it.
- **The details pane is data** (Justin, 2026-10-17): label/value rows, one number each, with the explanation in
  the row's tooltip. No sentences in the pane except the verdict and the warnings.

## Decisions (2026-10-16, M3)
- **List columns** (pass 2): Item (with the batch), Cost, Best exit (V/AH), Profit, ROI, Grade. The middle pane is
  about 376 px, so the separate vendor and AH figures live in the details pane.
- **Tray quantity** defaults to what you own (bags and bank), at least 1. A recipe is evaluated for the crafts the
  tray allows (at least 1); reagents not in the tray are bought: owned stock first, then the cheapest source.
- **Alt+Right-click** adds to the tray everywhere, and also price-checks at the AH (the tooltip has the stored prices).
- **Make-or-buy** only through recipes this character knows, depth 3, the highest yield first.
- **Defaults until M5:** cut 5%, sale chance 0.5, margin 20%, minimum grade C, owned materials at opportunity cost,
  **minimum profit 10s per craft** (Justin, 2026-10-16: 1g suits level 60 only). Deposits count as 0 until M4 caches
  them at the auctioneer.
- **Selling prices:** the lower of market value and min buyout; past 48 h, the fair value. **Buying:** the latest
  ladder; past 48 h, one level at the fair value. The grade shows the age either way.
- **Vendor cap** (Justin, 2026-10-16): an item a vendor sells is worth at most the vendor's price, both owned and sold.
- **Asks aren't sales** (Justin, 2026-10-16): the minimum grade stays C. The details pane shows the depth behind each AH
  price and flags one-price walls; persistence and the sales ledger (M4) will confirm demand.
- **Window 1,040 × 600:** the list's six columns and the 25-slot tray need it. It fits a 1366 × 768 UIParent.
- **Vendor goods are always available** (Justin, 2026-10-16):
  - recipes made entirely from vendor-sold reagents (vendor harvest + seed list) are listed even with nothing in the
    tray;
  - a vendor-sold tray reagent doesn't cap the batch.

  On 70425 no recipe is made from vendor goods alone yet; the list grows as more vendors are harvested.

## Decisions (2026-10-16, Justin)
- **Bag clicks:** Alt+Right-click is context-aware. At the AH it price-checks the item (targeted search) and adds it
  to the tray; anywhere else it only adds it to the tray. Plain right-click stays Blizzard's (use, sell or post).
  Drag-and-drop into the tray always works. Verified safe: modified bag clicks never use, sell or post [F-125].
- **Recipes:** all Forever recipes from a database generated from the Forever client's game tables, each flagged
  with the characters that know it, plus a "known only" filter.
- **Multiples:** quantities are first-class. Recipes needing several of one reagent, batches of N crafts, owned
  stock covering the first units, and the AH price ladder for the rest. The same item dropped twice merges.
- **No Auctionator code or design** (All Rights Reserved; its authors forbid use as a reference). Blizzard's
  source only.
- **Inform, don't automate:** posting and buying are restricted APIs; the player clicks.

## Decisions (2026-10-16, M1)
- **AH frame button:** yes (`UI\AHButton.lua`), under Blizzard's AH frame right of its tabs; our window is usually
  closed at the AH. Plain button, no hooks.
- **Econ.lua started in M1:** PriceDB needs `MarketValue` and `BuildLadder`; `/bf selftest` runs their vectors. M3 adds
  the rest.
- **Ladder:** 8 levels, more until 100 units are covered, at most 16.
- **Abort rule:** closing the AH aborts the read (nothing stored); once read, pricing finishes anyway.
- **Items keyed by itemID only:** suffix variants of green gear ("of the Bear") merge. Fine for reagents; revisit
  for gear in M4.
- **Market key:** normalized realm + faction (+ ":HC"); the beta gives `ClassicBetaPvP2-Horde` [F-083].

## Decisions (2026-10-16, M2)
- **Recipe data from the newest beta build** (70450). Regenerate with `recipe-catalog build --build <b>` when a build
  lands.
- **Recipes added after Classic are included but flagged 1** ("new"; not "era": 836 of the 860 are Forever-new, with
  spells ≥ 1.2M). They count as confirmed once a character knows them or their output is seen on the AH. A profession
  window listing them doesn't count: `GetAllRecipeIDs` lists the whole skill line, Season-of-Discovery recipes
  included, so `recipesSeen` was dropped (migration 1 → 2). M3 hides the unconfirmed ones by default.
- **Known recipes are read at login** with `C_SpellBook.IsSpellKnown` over the data, replacing the character's set
  (no window needed; verified on 592 recipes). The window harvest stays for diagnostics and same-session learning.
- **Enchant-only recipes are left out** (no item to price). Wands, oils and rods are in.
- **Vendor list from evidence only:** `tools/wowf/data/vendor_reagents.json`. `vendor-merge` adds what the merchant
  harvest saw on sale; its candidate printout is a review aid, not evidence.
- **Recipe rows are numeric arrays** (`{profession, minRank, yellowAt, greyAt, flags, output, count, reagent,
  count, ...}`); `RecipeIndex.Get` gives a readable copy.

## Architecture (planned files; build in this order)
| File | Job |
|---|---|
| `Core.lua` | namespace, SavedVariables + migrations, events, `ns.On/Fire` bus (exists) |
| `Util/Money.lua` | copper formatting via `C_CurrencyInfo.GetCoinTextureString`; local `COPPER_PER_GOLD` |
| `Util/Items.lua` | async item info cache (`ContinuableContainer`, `ITEM_DATA_LOAD_RESULT`) |
| `Pricing/PriceDB.lua` | per-market item prices: latest scan, ladder, packed daily history; prune; size guard |
| `Pricing/Scanner.lua` | full scan (ReplicateItems, time-sliced), cooldown estimate, diagnostics (AH open/close state is in Core) |
| `Pricing/Search.lua` | targeted search queue (throttled, one in flight, paged), split from Scanner for size |
| `Pricing/Merchant.lua` | vendor buy prices on MERCHANT_SHOW/UPDATE (`C_MerchantFrame.GetItemInfo`); the open merchant's slots for buying |
| `Pricing/Ledger.lua` | your sales, returns and auctions per market; measured cut; sale chance per item |
| `Pricing/Mail.lua` | AH mail read at the mailbox (invoices, expired/cancelled returns), counted once each |
| `Pricing/Deposits.lua` | deposits measured at the AH (all durations), deposit ÷ vendor price fit for the rest |
| `Pricing/Owned.lua` | your active auctions (QueryOwnedAuctions): what's listed, item names for sales mail |
| `Pricing/Flips.lua` | AH flips: listings below a vendor's price, found in each full scan and renewed by each search; the AH flips view's rows |
| `Data/Recipes.lua`, `Data/Vendor.lua` | generated by `tools/wowf/recipe_catalog.py` (M2); IDs and numbers only |
| `Crafting/Harvest.lua` | known recipes per character from the profession window |
| `Crafting/RecipeIndex.lua` | reagent → recipes reverse index; filters (profession, known only, skill) |
| `Economics/Econ.lua` | pure functions from the wowf-economics references (MarketValue, FairValue, CostToBuy, AHNet, Acquire) |
| `Economics/Evaluator.lua` | per recipe: COGS by source, exits, profit, ROI, value added, grade, recommendation |
| `Pricing/Buy.lua` | the Buy bar's purchases, one per click: AH reagents and stackable flips by quote, gear by PlaceBid, vendor reagents by BuyMerchantItem; the `/bf buytest` probe |
| `Pricing/Collect.lua` | what BuffettForever bought that's still in the mailbox (charDB.bought, the drop rule) and taking it (Collect, one attachment per click); `/bf mailtest` |
| `Pricing/Post.lua` | posting the crafted items at the AH; the `/bf posttest` probe |
| `Crafting/Craft.lua` | crafting a known recipe from the bags and the tray's debit; the `/bf crafttest` probe |
| `UI/MailButton.lua` | the Collect button under Blizzard's mail window |
| `UI/ReagentTray.lua`, `UI/ResultsList.lua`, `UI/DetailPanel.lua` | fill the panes the raw window already lays out |
| `UI/BuyBar.lua` | the Buy bar under the details in Profession profits (Crafts, Best, Buy) and AH flips (Buy); live prices at the AH |
| `Bags.lua` | Alt+Right-click post-hook on `HandleModifiedItemClick` |
| `Tooltip.lua` | AH / vendor / fair-value lines via `TooltipDataProcessor` |

## Data model (SavedVariables)
- `BuffettForeverDB` (account): `markets[marketKey].items[itemID] = { t, mv, min, q, n, ladder = "p:q,...", h = { [day] = "mv:min:qty:n:k" } }`,
  `markets[marketKey].ledger = { items[itemID] = { s, e, c, bid, cut, b, paid, t }, s, e, c, cut = { bid, cut, n }, names, pending, seen, listed, listedAt }`,
  `vendor[itemID] = { p = unitCopper, t, lim }`, `deposits[itemID] = { d1, d2, d3, s = vendor price, t }`,
  `recipesKnown[charKey][recipeID] = true`, `settings`, `minimap`, `diag`.
- `BuffettForeverCharDB` (character): `window`, tray contents, last selection,
  `bought[itemID] = { q still in the mailbox, t last purchase, k kind }` (Pricing/Collect.lua).
- `marketKey`: one function. Start with realm + faction (+ ":HC" when `C_GameRules.IsHardcoreActive()`); change it
  once the probes show which characters share an AH (the AH is per ruleset [F-081]).
- `charKey`: full "First Surname" name (never name-realm [F-080]).

## Milestones
- **M1 prices:** PriceDB, Scanner (full + targeted), Merchant, Bags hook, Tooltip lines, status line + scan button
  in the window (enabled only at the AH), `SAVED_VARIABLES_TOO_LARGE` read-only guard.
- **M2 recipes:** `tools/wowf/recipe_catalog.py` + tests, modelled on `music_catalog.py` (SkillLine,
  SkillLineAbility, SpellReagents, SpellEffect, SpellName, ItemSparse, Item; profession lines only; output and
  reagents must exist in ItemSparse) → `Data/Recipes.lua`; a reviewed vendor seed list in
  `tools/wowf/data/vendor_reagents.json` → `Data/Vendor.lua`; Harvest + RecipeIndex.
- **M3 tray and evaluator:** ReagentTray (drag, Alt+Right-click, merge, remove, "load from bags"), Econ +
  Evaluator, ResultsList (sortable, top-pick banner), DetailPanel (source badges, exits), `/bf selftest` running the
  test vectors in the wowf-economics references.
- **M4 depth:** confidence grades, Mr. Market hints, vendor-flip and craft-to-vendor scanners, batch-size advice,
  value-added column, profit per hour.
- **M5 publish:** Settings (cut, margin of safety, minimum profit, owned-materials policy, history days, sale chance),
  README/CurseForge page (`docs/BuffettForever-curseforge.md`), screenshots, `package BuffettForever`.

## Economics defaults (wowf-economics; settings since 0.8.0, Options.lua)
Cut 5% until measured; sale chance per listing 0.5 until your sales say otherwise; margin of safety 20%; minimum
profit 10s per craft (the reference's 1g suits level 60); minimum grade C; history 14 days; deposits at the
auction length the AH remembers; owned materials at opportunity cost. Not settings: half-life 3 days, stale after
48 h, make-or-buy depth 3.

## Open questions and probes (run in game; record Forever facts in forever-facts.md, decisions here)
- Answered on 70425 by the scanner's `diag` [F-121]:
  - the replicate index is 0-based;
  - reagents are commodities;
  - copper values are supported;
  - the cooldown is between 14.6 and 18.7 min (2026-10-17, from the request log), consistent with retail's 15 min,
    which is the scanner's estimate.
- Still open:
  - the AH cut (seller invoice);
  - who shares an AH (sets `marketKey`): scan with an Alliance character and compare the ladders.
- Answered by M4 pass 1's diagnostics on 70425: the AH mail subjects and sender, unread mail stays unread,
  `daysLeft` is a snapshot [F-130]; the deposit formula, the 1s minimum, durations 2/8/24 h, the call answers
  away from the AH [F-129].
- Answered on 70425 (2026-10-17): an owned commodity auction's `buyoutAmount` is per unit [F-131].
- Still open from M4: the house cut (a sale); an expired auction's mail (counted as expired).
- `GetRecipeSchematic` with the profession window closed, and for recipes the character doesn't know.
- `GetAllRecipeIDs` signature; does `IsPlayerSpell(recipeID)` report learned recipes without the window?
- Merchant `numAvailable` for unlimited stock.
- Which of the 1,169 high-ID (Season of Discovery era) recipes exist on Forever: confirm through harvests.
The probe lines are in auction-house.md and professions-and-vendors.md.

## Working here
- Tools run from this folder through the skill shims, or directly: `python ../tools/wowf/cli.py lint BuffettForever`,
  `python ../tools/wowf/cli.py package .`, `python ../tools/wowf/cli.py make-icon --design coin`; deploy with the
  wowf-deploy skill (the beta client has a junction to this folder).
- `.claude/settings.json` grants `..` as a working directory, so the shared skills and tools are readable and
  editable; edits under `.claude/` still ask first (protected path). If `/permissions` doesn't list `AddOns\`
  as a working directory, put the absolute path in a gitignored `.claude/settings.local.json` instead.
- Knowledge capture (workspace CLAUDE.md): Forever facts → forever-facts.md; AH/profession API flows →
  auction-house.md / professions-and-vendors.md; pricing math → wowf-economics; tool gaps → `tools/wowf` + a
  test; addon-only decisions → this file. Commit shared changes separately (`skills:`, `tools:`, `BuffettForever:`).
