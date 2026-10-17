# Changelog

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
