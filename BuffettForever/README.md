# BuffettForever

*by Typheous*

Auction House scanner and crafting ROI advisor for World of Warcraft: Forever: what to craft, where to sell
it, and the return on every gold piece.

> **Status: 0.4.0, early development.** Auction House prices, Forever's recipes, the reagent tray and the crafting
> evaluator (`/bf eval`) work; the result and detail panes arrive next.

- **Auction House prices:** scan the whole Auction House while you talk to an auctioneer, or price-check one item
  with **Alt+Right-click** in your bags (away from the AH it shows the stored prices). Prices are kept with their
  history, so one odd scan doesn't fool you, and item tooltips show the market value, min buyout and vendor
  prices.
- **Reagent tray:** drop up to 10 crafting materials into the tray (drag them in, or Alt+Right-click them) and see
  every recipe that uses them, from every profession, with the ones your characters know marked.
- **Cost vs. sale:** each recipe shows what its materials cost (vendor, Auction House, crafting them yourself, or
  what the ones you own are worth) against what the result sells for at a vendor or on the Auction House,
  after the house cut and deposits.
- **ROI and a recommendation:** the return on investment for every recipe, where to sell it, and a top pick, with
  a margin of safety so thin or stale deals aren't recommended.

## Commands
- `/bf` or `/buffett`: open or close the window
- `/bf scan`: scan the whole Auction House (at an auctioneer; also the **Scan** buttons in the window and under
  the Auction House frame)
- `/bf recipes <item link or ID>`: the recipes that use or make an item
- `/bf eval`: the best recipes for the reagents in your tray, with cost, best exit, profit, ROI and confidence
- `/bf options`: settings
- `/bf diag`: scanner diagnostics; `/bf selftest`: check the price math and the recipe data
- `/bf minimap`: show or hide the minimap button
- `/bf help`: list commands

## How it works
WoW Forever addon (interface 16001), built in the wow-forever-workspace. Prices come from the Auction House API
while you're at an auctioneer; recipe data comes from the Forever client's own game tables; vendor prices from
the item data and the merchants you visit. SavedVariables: `BuffettForeverDB` (account) and
`BuffettForeverCharDB` (character).
