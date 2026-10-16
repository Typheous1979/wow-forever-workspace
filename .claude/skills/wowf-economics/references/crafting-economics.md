# Crafting economics: cost of goods, exits, ROI

A recipe turns reagents `{ (item, qty) }` into `yield` units of an output item (average of the schematic's
`quantityMin..quantityMax`, or the table count). Evaluate a **batch** of `N` crafts: buying more of an input
walks up its price ladder, and owned stock covers the first units.

## 1. What each reagent costs: pick the cheapest source
| Source | Unit cost | Certainty | Notes |
|---|---|---|---|
| **Owned** | opportunity cost = max(vendor sell, AH net) | certain | only for the units you hold; never 0 (sunk-cost fallacy) |
| **Vendor** | merchant price / stackCount | certain, instant | unlimited unless `numAvailable` says otherwise |
| **AH** | `CostToBuy(ladder, need) / need` | depends on data age | depth-aware; flag "can't fill" |
| **Craft** | cost of the sub-recipe / its yield | as good as its inputs | recursive (make-or-buy), depth ≤ 3, cycle guard |

Consume owned stock first, then buy the remainder from the cheapest acquisition source. Ties go to the simpler
source (vendor, then AH, then craft). Record the source of every line; the detail panel shows it.
The owned-materials policy is a setting: **opportunity cost** (default), **free** (sunk), or **replacement**
(what it would cost to buy again).

## 2. Exits: where the output can go
- **Vendor** = vendor sell × yield × N. Instant, certain, no fees; unavailable when the sell price is 0.
- **AH net per unit** = `price × (1 − cut) − deposit × (1 − p) / p`
  - `price`: the conservative sell price, the lower of the latest market value and min buyout (price-estimation.md).
  - `cut`: the house cut (measured from invoices; default 0.05).
  - `deposit`: per unit, from `Calculate*Deposit` (cached).
  - `p`: chance a listing sells before it expires. Each failed listing loses its deposit, so the expected
    deposits lost before a sale are `deposit × (1 − p) / p` (a geometric series). Default 0.5.
  - Unavailable for BoP outputs (`bindType == 1`) and when there's no price data (unknown, not 0).
- **Disenchant** (later): the expected value of the materials, an exit only enchanters have.
- **Best exit** = the highest available, subject to the margin-of-safety rule (risk-and-recommendation.md): the AH
  must beat the vendor by the margin, otherwise take the certain vendor exit.

```lua
local addonName, ns = ...
local Econ = ns.Econ or {}
ns.Econ = Econ

function Econ.AHNet(price, cut, deposit, p)
    if not price then return nil end
    deposit, p = deposit or 0, p or 0.5
    return price * (1 - (cut or 0.05)) - deposit * (1 - p) / p
end

-- Liquidation value of one unit you own: the better of selling it to a vendor or on the AH.
function Econ.Liquidation(vendorSell, ahNet)
    if ahNet and vendorSell then return math.max(vendorSell, ahNet) end
    return ahNet or vendorSell
end
```

## 3. Profit, ROI and value added
- **Cost of goods (COGS)** = Σ over reagents of the cost of `qty × N` units from section 1.
- **Profit** = best exit − COGS. **ROI** = profit / COGS.
  - COGS = 0 (everything owned and valued as free): ROI is undefined. Show "∞" and rank by profit.
  - Negative ROI is a loss: show it in red and never recommend it.
  - Show absolute profit per craft and per batch next to ROI. 900% on 2 copper isn't an opportunity.
- **Value added** = best exit − Σ liquidation value of all inputs. It answers "is crafting better than selling my
  materials raw?": negative means sell the materials instead.
- **Profit per hour** (optional): profit per craft × crafts per hour, from the recipe's cast time plus overhead.

## 4. Make-or-buy recursion
```lua
-- Cheapest way to obtain `qty` of itemID. ctx supplies vendorBuy[id], ladder[id], recipeFor[id], owned[id].
-- Returns cost, source ("owned", "vendor", "ah", "craft", or nil when no source is known).
function Econ.Acquire(itemID, qty, ctx, depth, visiting)
    depth, visiting = depth or 0, visiting or {}
    local best, source
    local unit = ctx.vendorBuy[itemID]
    if unit then best, source = unit * qty, "vendor" end
    local ladder = ctx.ladder[itemID]
    if ladder then
        local cost, filled = Econ.CostToBuy(ladder, qty)
        if filled and (not best or cost < best) then best, source = cost, "ah" end
    end
    local recipe = ctx.recipeFor[itemID]
    if recipe and depth < 3 and not visiting[itemID] then
        visiting[itemID] = true
        local crafts = math.ceil(qty / recipe.yield)
        local cost = 0
        for i = 1, #recipe.reagents, 2 do
            local c = Econ.Acquire(recipe.reagents[i], recipe.reagents[i + 1] * crafts, ctx, depth + 1, visiting)
            if not c then cost = nil; break end
            cost = cost + c
        end
        visiting[itemID] = nil
        if cost and (not best or cost < best) then best, source = cost, "craft" end
    end
    return best, source
end
```
Owned stock is applied before calling `Acquire` for the remainder (section 1). Cache results per batch, and
recompute when prices change.

## 5. Worked examples
**Smelt Bronze, vendor only (real Forever numbers, ItemSparse 70245).** 1 Copper Bar (vendor sell 10c) + 1 Tin Bar
(35c) → 2 Bronze Bars (50c each). Inputs worth 45c at a vendor become 100c at a vendor: profit 55c, ROI 122%,
with no AH risk at all. That's a "craft-to-vendor" find (strategy-ideas.md). Check the sell prices in game first.

**Bolt of Linen Cloth, batch of 10 (AH prices illustrative).** 2 Linen Cloth → 1 Bolt. Vendor sell: Linen 13c,
Bolt 40c (ItemSparse 70245). AH: Linen ladder 9.50s × 20, 10s × 40, 11s × 100 (market 10s, min 9.50s); Bolt market
30s, min 29s. Cut 5%, deposit ignored. You own 6 Linen and need 20.
- Owned Linen: liquidation = max(13c, 9.50s × 0.95 = 9.025s) = 9.025s → 6 × 9.025s = 54.15s.
- Buy 14 Linen from the ladder: 14 × 9.50s = 1g 33s. **COGS = 1g 87.15s** (18,715c).
- Exits: vendor 10 × 40c = 4s. AH: min(30s, 29s) × 0.95 = 27.55s per bolt → 2g 75.50s. Best = AH.
- **Profit = 88.35s; ROI = 47.2%.** Value added over selling all 20 Linen = 2g 75.50s − 20 × 9.025s = 95s.
- With a 60c deposit per bolt and p = 0.5: AH exit 2g 69.50s, profit 82.35s, ROI 44.0%.

## 6. Test vectors (for `/<addon> selftest`; computed independently in Python)
| Case | Setup | Expected |
|---|---|---|
| CRAFT-1 | the Bolt example above, deposit 0 | COGS 18715; AH exit 27550; vendor exit 400; profit 8835; ROI 0.47208; value added 9500 |
| CRAFT-2 | CRAFT-1 with deposit 60/unit, p 0.5 | AH exit 26950; profit 8235; ROI 0.44002 |
| VENDOR-1 | Smelt Bronze, inputs at vendor sell, 1 craft | COGS 45; vendor exit 100; profit 55; ROI 1.22222 |
| MOB-1 | need 4 Bronze Bars; AH 80c × 10; craft = Copper Bar 60c + Tin Bar 90c per 2 bars | buy 320 vs craft 300 → "craft" |
| NET-1 | `AHNet(2900, 0.05, 60, 0.5)` | 2695 |
| ROI-0 | COGS 0, exit 500 | ROI nil, rank by profit 500 |
