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
- CV (coefficient of variation) = standard deviation / mean of the daily market values in the window.
- A recipe's grade is the lowest grade among its AH-priced lines and its AH exit. Show it next to the ROI.
- For ranking you may risk-adjust: weight ROI by A 1.0, B 0.9, C 0.7, D 0.4. Display the raw ROI with the grade.

## Liquidity and saturation
- **Depth**: quantity listed now. **Persistence**: days seen in the window / 14. **Competition**: number of auctions
  (and `containsOwnerItem` in search results: are you already the cheapest seller?).
- Batch advice for outputs: keep `N × yield` at or below about a quarter of the typical listed quantity, and warn
  when it exceeds the whole listed quantity ("you'd be the entire market"). No listings means demand is
  **unknown**, not high.
- Marginal analysis: each extra craft buys inputs higher up the ladder and sells at a lower price. Stop when the
  next craft's profit drops below zero; that's the batch cap. Owned stock and `GetMoney()` cap it too.

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
- BoP outputs: vendor exit only. Enchants: no item, no exit.
- Daily-cooldown recipes: value per cooldown, not per craft (strategy-ideas.md).
- Long auction durations raise the deposit; the expected deposit loss grows as `p` falls.
