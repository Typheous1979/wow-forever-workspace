# Risk, confidence and recommendations

A recommendation is only as good as its worst input. This page turns data quality into a grade, applies the
margin of safety, ranks the candidates and words the advice.

## Confidence grade per price
| Grade | Latest scan | Days observed (of 14) | Volatility (CV) | Depth |
|---|---|---|---|---|
| **A** | < 24 h | ≥ 5 | < 0.15 | listed ≥ 2 × what you need |
| **B** | < 48 h | ≥ 3 | < 0.30 | listed ≥ what you need |
| **C** | < 7 days | ≥ 1 | < 0.60 | some listed |
| **D** | older, or never | single observation | ≥ 0.60 | can't fill |

- A price takes the **lowest** grade any column gives it. Vendor prices are always A (fixed and certain).
- **A sell price in a wall that never shrinks is D.** The cheapest price has held (within 1%) for 3 observed days
  while the quantity listed never fell, so nobody seems to buy at that price. It doesn't apply once you've sold
  the item yourself, nor to prices you buy at (a stable price is good for buying).
- CV (coefficient of variation) = standard deviation / mean of the daily market values in the window.
- A recipe's grade is the lowest grade among its AH-priced lines and its AH exit. Show it next to the ROI.
- For ranking you may risk-adjust: weight ROI by A 1.0, B 0.9, C 0.7, D 0.4. Display the raw ROI with the grade.

## Liquidity and saturation
- **Depth**: quantity listed now. **Persistence**: days seen in the window / 14. **Competition**: number of auctions
  (and `containsOwnerItem` in search results: are you already the cheapest seller?).
- **Your own auctions aren't the market.** Leave them out of the listings before pricing, or your own wall
  looks like depth, sets the price you compete with, and passes as demand:
  - full scans: subtract your auctions (`GetOwnedAuctions`: unit price, quantity) from the listings at their price;
  - searches: `numOwnerItems` in commodity rows, `containsOwnerItem` in item rows (auction-house.md).
- **Market cap:** sell at most a quarter of what's listed at once, `floor(listed × 0.25 ÷ yield)` crafts, and warn
  when the batch is bigger. No listings means demand is **unknown**, not high.
- **Best batch** = the smaller of two independent limits; say which one set it.
  - Reagents (marginal analysis): each extra craft buys inputs higher up the ladder. Evaluate every batch size from
    1 up to 200, stopping where the reagents can't all be had, and take the one with the most profit (the smallest
    wins a tie).
  - Market: the market cap above.
  - Don't bound the reagent search by the market cap. With a fixed sell price, profit keeps growing with every
    craft, so a capped search only finds the cap again. BuffettForever 0.6.0 did that at first, and best batch
    equalled the cap for 90 of 155 recipes on 70425.
  - Owned stock and `GetMoney()` cap it too.

## Margin of safety (defaults: 20%, minimum profit 1g per craft, minimum grade C)
1. **AH or vendor?** Choose the AH only if `AH net ≥ vendor × (1 + margin)`. Otherwise sell to the vendor: it's
   certain, instant and free.
2. **Craft or not?** Recommend only if ROI ≥ margin, profit ≥ the minimum, grade ≥ the minimum, and the ladder can
   fill every input.
3. **Craft or sell raw?** With owned materials, recommend crafting only if value added ≥ margin × liquidation value
   of the inputs; otherwise say "sell the materials".

## Ranking
1. Filter out losses, unknown prices, grades below the minimum, and profit under the minimum.
2. Sort by ROI (or risk-adjusted ROI), highest first; break ties by absolute profit.
3. **Top pick** = the first row. Also show **best absolute profit** when it's a different recipe: players with
   capital care about gold per craft, not just percentages.
4. Keep everything visible in the list (greyed when filtered) so the player can see why something isn't recommended.

## Wording (state the action, the number, the reason)
- "Craft 10 × Bolt of Linen Cloth and sell on the AH: +88s 35c (ROI 47%, confidence A). A vendor pays 4s."
- "Sell to a vendor: the AH beats it by only 8%, under your 20% margin of safety."
- "Don't craft: you'd lose 75c per craft. Sell the Copper and Tin Bars instead (+9s)."
- "Not enough data: Linen Cloth hasn't been scanned in 9 days. Scan at the Auction House."
- "Only 160 Linen Cloth listed; this batch needs 200."

## Pitfalls
- ROI on tiny amounts: always pair it with absolute profit and a minimum.
- Stale data looks precise: show the age, grade it, and refuse to rank D-grade results as the top pick.
- "Expensive" items with one listing: one ask isn't a market (depth and persistence catch it).
- **A wall of identical asks isn't a market either.** On the beta (70425), many crafted outputs were listed as walls
  at one price: 97 Azure Gustwoven Bracers all at exactly 44s, 8 Handstitched Leather Belts at 90s–1g, so a
  belt from 3s of materials showed 2,775% ROI. Depth alone passes them. Show the depth next to the price, flag
  one-price walls, and grade a wall that hasn't shrunk in 3 days D for selling (see the grades above). Your own
  sales of the item lift that.

## Test vectors (computed in tools/wowf/econ.py; BuffettForever's /bf selftest replays them)
| Case | Setup | Expected |
|---|---|---|
| WALL-1 | days (price, listed) 44s/90, 44s/95, 44s/97 | 3 days at 44s |
| WALL-2 | 44s/97, 44s/90, 44s/95 | 2 (the quantity fell once) |
| WALL-3 | 45s/90, 44s/95, 44s/97 | 2 (the price moved) |
| WALL-4 | 44s/90, 44.30s/90, 44.10s/95 | 3 (within 1%) |
| OWN-1 | listings 29s × 20, 29s × 8, 31s × 5; yours 29s × 20 | 29s × 8, 31s × 5; 20 removed |
| OWN-2 | the same; yours 29s × 25 | 29s × 3, 31s × 5; 25 removed |
| OWN-3 | listings 29s × 20; yours 50s × 2 | unchanged |
| BATCH-LADDER | 2 Linen per Bolt (AH net 27.55s); Linen 20 at 9.50s, then 100 at 20s; tray 20 crafts | reagents: most profit at 10 (+85s 50c), dry after 60; cap 250 of 1,000 listed; batch 10, set by the reagents (20 lose 39s) |
| BATCH-CAP | Linen cheap and deep; 40 Bolts listed; tray 20 | reagents: still growing at 200; cap 10; batch 10, set by the market |
| BATCH-VENDOR | Smelt Bronze from vendor bars, sold to a vendor | still growing at 200, no cap: no limit |
- BoP outputs: vendor exit only. Enchants: no item, no exit.
- Daily-cooldown recipes: value per cooldown, not per craft (strategy-ideas.md).
- Long auction durations raise the deposit; the expected deposit loss grows as `p` falls.
- **Small posts of cheap items lose money on Forever.** Every auction pays at least a 1s deposit [F-129], so 2
  Coarse Thread at 19c each risk 1s to earn 36c. Advise posting a batch in one auction, or selling cheap goods to
  a vendor.
