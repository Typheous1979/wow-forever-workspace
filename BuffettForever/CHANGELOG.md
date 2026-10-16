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

## 0.1.0 (not released)
- Scaffolded with the workspace generator: window (layout only: reagent tray, top pick, craftable items,
  details, status line), coin icon, minimap button, addon compartment entry, `/bf` and `/buffett`, Settings panel.
- Tested on build: 1.60.1.70425 (beta), 2026-10-16
