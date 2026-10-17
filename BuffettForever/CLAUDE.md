# BuffettForever — addon notes

Addon-only context for Igor. The workspace CLAUDE.md, the wowf skills and the shared memory load from the
parent folders (the workspace root is `..`), so this file holds only what is specific to BuffettForever.
Not shipped (package.py leaves CLAUDE.md out). Skills to load for this addon: `wowf-addon-dev` (read
auction-house.md and professions-and-vendors.md) and `wowf-economics`.

## Purpose
Scan the Auction House, keep prices for every item, and advise on crafting. The player drops up to 10 reagents
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
| `Pricing/Invoices.lua` | AH cut from seller invoices (`GetInboxInvoiceInfo`), later the sales ledger |
| `Data/Recipes.lua`, `Data/Vendor.lua` | generated by `tools/wowf/recipe_catalog.py` (M2); IDs and numbers only |
| `Crafting/Harvest.lua` | known recipes per character from the profession window |
| `Crafting/RecipeIndex.lua` | reagent → recipes reverse index; filters (profession, known only, skill) |
| `Economics/Econ.lua` | pure functions from the wowf-economics references (MarketValue, FairValue, CostToBuy, AHNet, Acquire) |
| `Economics/Evaluator.lua` | per recipe: COGS by source, exits, profit, ROI, value added, grade, recommendation |
| `UI/ReagentTray.lua`, `UI/ResultsList.lua`, `UI/DetailPanel.lua` | fill the panes the raw window already lays out |
| `Bags.lua` | Alt+Right-click post-hook on `HandleModifiedItemClick` |
| `Tooltip.lua` | AH / vendor / fair-value lines via `TooltipDataProcessor` |

## Data model (SavedVariables)
- `BuffettForeverDB` (account): `markets[marketKey].items[itemID] = { t, mv, min, q, n, ladder = "p:q,...", h = { [day] = "mv:min:qty:n" } }`,
  `vendor[itemID] = { p = unitCopper, t, lim }`, `recipesKnown[charKey][recipeID] = true`, `settings`, `minimap`.
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

## Economics defaults (wowf-economics; make them settings in M5)
Cut 5% until measured; sale chance per listing 0.5; margin of safety 20%; minimum profit 1g per craft; history
14 days, half-life 3 days; stale after 48 h; make-or-buy depth 3; owned materials at opportunity cost.

## Open questions and probes (run in game; record Forever facts in forever-facts.md, decisions here)
- Answered on 70425 by the scanner's `diag` [F-121]:
  - the replicate index is 0-based;
  - reagents are commodities;
  - copper values are supported;
  - the cooldown is over 2 min.
- Still open:
  - the cooldown's exact length (the `diag.requests` log measures it);
  - the AH cut (seller invoice);
  - who shares an AH (sets `marketKey`): scan with an Alliance character and compare the ladders.
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
