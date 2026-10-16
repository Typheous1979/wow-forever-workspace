# Changelog

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
