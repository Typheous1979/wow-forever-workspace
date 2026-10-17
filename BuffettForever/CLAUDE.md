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
- **Tests logged for later** (Justin, 2026-10-17: "in future builds"): the house cut, once 3 sales worth 1g in
  all have come by mail (`/bf ledger` shows the measured cut). The expiry and mailbox-reopen tests passed on
  70425 (2026-10-17).

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
| `Pricing/Merchant.lua` | vendor buy prices on MERCHANT_SHOW/UPDATE (`C_MerchantFrame.GetItemInfo`) |
| `Pricing/Ledger.lua` | your sales, returns and auctions per market; measured cut; sale chance per item |
| `Pricing/Mail.lua` | AH mail read at the mailbox (invoices, expired/cancelled returns), counted once each |
| `Pricing/Deposits.lua` | deposits measured at the AH (all durations), deposit ÷ vendor price fit for the rest |
| `Pricing/Owned.lua` | your active auctions (QueryOwnedAuctions): what's listed, item names for sales mail |
| `Pricing/Flips.lua` | AH flips: listings below a vendor's price, found in each full scan; the AH flips view's rows |
| `Data/Recipes.lua`, `Data/Vendor.lua` | generated by `tools/wowf/recipe_catalog.py` (M2); IDs and numbers only |
| `Crafting/Harvest.lua` | known recipes per character from the profession window |
| `Crafting/RecipeIndex.lua` | reagent → recipes reverse index; filters (profession, known only, skill) |
| `Economics/Econ.lua` | pure functions from the wowf-economics references (MarketValue, FairValue, CostToBuy, AHNet, Acquire) |
| `Economics/Evaluator.lua` | per recipe: COGS by source, exits, profit, ROI, value added, grade, recommendation |
| `UI/ReagentTray.lua`, `UI/ResultsList.lua`, `UI/DetailPanel.lua` | fill the panes the raw window already lays out |
| `Bags.lua` | Alt+Right-click post-hook on `HandleModifiedItemClick` |
| `Tooltip.lua` | AH / vendor / fair-value lines via `TooltipDataProcessor` |

## Data model (SavedVariables)
- `BuffettForeverDB` (account): `markets[marketKey].items[itemID] = { t, mv, min, q, n, ladder = "p:q,...", h = { [day] = "mv:min:qty:n:k" } }`,
  `markets[marketKey].ledger = { items[itemID] = { s, e, c, bid, cut, b, paid, t }, s, e, c, cut = { bid, cut, n }, names, pending, seen, listed, listedAt }`,
  `vendor[itemID] = { p = unitCopper, t, lim }`, `deposits[itemID] = { d1, d2, d3, s = vendor price, t }`,
  `recipesKnown[charKey][recipeID] = true`, `settings`, `minimap`, `diag`.
- `BuffettForeverCharDB` (character): `window`, tray contents, last selection.
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
