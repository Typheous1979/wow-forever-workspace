---
name: wowf-economics
description: Gold-making economics for World of Warcraft Forever addons such as BuffettForever. Robust auction price estimation (lower-quantile trimmed mean, decay-weighted history, staleness), depth-aware purchase cost from the price ladder, the house cut and expected deposit loss, the vendor floor, cost of goods with make-or-buy recursion, opportunity cost of owned materials, ROI and profit ranking, value added versus selling raw materials, liquidity, volatility and confidence grades, margin-of-safety recommendations, arbitrage scanners, and which in-game data feeds each input. Use when designing, coding or reviewing pricing, crafting profit, ROI, recommendation, arbitrage or market-analysis logic in an addon, or when asked what to craft, where to sell, or how to value items or inventory.
when_to_use: BuffettForever, ROI, profit, market value, crafting cost, cost of goods, auction price, vendor price, make or buy, margin of safety, gold making, flipping
---

# Economics for Forever addons

This skill is the math and the decisions. The APIs that feed it live in `wowf-addon-dev`:
auction-house.md (scans, searches, deposits, the cut) and professions-and-vendors.md (recipes, vendor prices,
money formatting). All amounts are **copper**; keep full precision and round only for display.

## Principles (Buffett's rules, applied to crafting)
1. **Rule No. 1: never lose money.** The vendor price is a guaranteed, instant, fee-free exit: the floor of an
   item's value. Flag negative expected value loudly; prefer the certain exit when margins are thin.
2. **Margin of safety.** Recommend the AH over the vendor, or crafting over selling raw, only when it wins by a
   clear margin after fees, using conservative prices (sell low, buy high).
3. **Mr. Market.** One scan is a mood, not a price. Use robust estimators and history; treat big deviations from
   fair value as opportunities, not truth.
4. **Opportunity cost, not sunk cost.** Materials you own aren't free: they're worth what you could sell them for.
5. **Circle of competence.** Prefer recipes the player knows and markets with enough data to trust.
6. **Show your work.** Every number on screen can explain itself: source (vendor, AH, craft, owned), quantity,
   unit cost, fees, age and confidence.

## Inputs and where they come from
| Input | In-game source | Notes |
|---|---|---|
| AH listings (unit price, quantity) | full scan `ReplicateItems`, or a targeted search | only at the auctioneer; age matters |
| Vendor sell price | `C_Item.GetItemInfo` 11th return | static per build; 0 = can't vendor |
| Vendor buy price | merchant harvest (`C_MerchantFrame.GetItemInfo`), seeded from ItemSparse `BuyPrice` for known vendor items | includes reputation discounts |
| Recipes: reagents, quantities, yield | Forever game tables (wago.tools), checked with `GetRecipeSchematic` | per build |
| Known recipes | profession-window harvest (or `IsPlayerSpell` if the probe passes) | per character |
| Owned quantities | `C_Item.GetItemCount(id, includeBank)` | live |
| Bind type | `C_Item.GetItemInfo` 14th return (1 = BoP) | BoP has no AH exit |
| Deposit | `CalculateCommodityDeposit` / `CalculateItemDeposit` at the AH | cache per unit and duration |
| AH cut | seller invoices: consignment / bid | measure once, keep as a setting |
| Budget | `GetMoney()` | live |
| Realized sales | AH mail invoices (`GetInboxInvoiceInfo`) | ground truth for sell-through |

## Default parameters (make each a setting)
| Parameter | Default | Why |
|---|---|---|
| AH cut | 0.05 | retail's rate; unmeasured on Forever [F-122] |
| Sale chance per listing `p` | 0.5 | drives expected deposit loss until real sell-through data exists |
| Lower-quantile window | 15% of quantity, up to 30% unless the price jumps >20% | robust "typical cheapest" price |
| Outlier cut | 2σ around the window's weighted mean | drops troll and fat-finger listings |
| History | 14 days, half-life 3 days | fair value without overreacting |
| Stale after | 48 h (warn), 7 days (grade D) | old data misleads |
| Margin of safety | 20% | AH must beat vendor (and crafting must beat raw) by this much |
| Minimum profit | 1g per craft | ROI on tiny numbers misleads |
| Make-or-buy depth | 3 | covers bars → parts → item |
| Owned materials | opportunity cost | alternatives: free (sunk), replacement (buy cost) |

## Workflow
1. Name the decision: what to craft? where to sell? buy or make this reagent? is this listing a bargain?
2. Gather inputs with their age and source (table above). Missing data is "unknown", never 0.
3. Compute with the reference functions: price-estimation.md (prices), crafting-economics.md (cost, exits,
   ROI), risk-and-recommendation.md (confidence, ranking, wording).
4. Rank, filter and explain: show the winner and the runner-up, with the numbers behind each.
5. Test: there's no offline Lua runtime, so ship a `/<addon> selftest` that runs the test vectors in
   crafting-economics.md and price-estimation.md and prints pass/fail. Then have **a second implementation
   check the first**. BuffettForever's `tools/wowf/econ.py` reimplements the math in Python:
   - `econ vectors` generates branch scenarios with Python's results (`Economics/EvaluatorVectors.lua`), and the
     selftest replays them against the Lua.
   - `econ check` replays a snapshot that `/bf eval` saves in SavedVariables (every input it looked up, plus its
     ranked results), recipe by recipe, on the player's real data.

   Keep "unknown" (nil/false) and 0 apart in both implementations: 0 is truthy in Lua.

## References
| File | Read when |
|---|---|
| `references/price-estimation.md` | Turning scans into prices: market value, min buyout, history, staleness, the price ladder, storage |
| `references/crafting-economics.md` | Cost of goods, make-or-buy, owned materials, exits, ROI, value added, worked examples and test vectors |
| `references/risk-and-recommendation.md` | Confidence grades, volatility, liquidity, margin of safety, ranking, batch size, how to word advice |
| `references/strategy-ideas.md` | Features beyond ROI: arbitrage scanners, skill-up cost, cooldowns, inventory valuation, a sales ledger |
