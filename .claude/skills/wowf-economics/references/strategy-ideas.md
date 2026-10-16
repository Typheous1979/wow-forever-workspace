# Strategy ideas beyond ROI

Features that use the same data. Each lists its inputs and which are available on Forever today.

## Rule No. 1 scanners (risk-free finds)
- **Vendor flip.** Any AH listing whose unit price is below the item's vendor sell price is free money: buy it,
  vendor it. Inputs: the full scan plus `sellPrice`. Show it as a list after each scan; buying stays a
  player click (purchases are restricted, and the player decides).
- **Craft-to-vendor.** Recipes whose vendor exit beats the cost of vendor-bought or owned inputs. Real example on
  70245: Smelt Bronze turns 45c of bars into 100c (crafting-economics.md). Inputs: the recipe tables,
  ItemSparse sell prices, merchant prices.
- **Under-priced intermediates.** An intermediate (bars, bolts, leathers) listed below the cost of its inputs:
  buy it instead of making it, or buy the inputs and sell the intermediate when the gap reverses.

## Mr. Market signals
- z-score of today's market value against fair value: `z = (now − fair) / σ` over the window.
  - z < −1: inputs are cheap; stock up for planned crafts.
  - z > +1: outputs are dear; sell what you hold.
- Show signals as hints, never as orders; a thin market can produce any z.

## Profession planning
- **Cheapest skill-up path.** SkillLineAbility gives each recipe's `MinSkillLineRank` and the yellow and grey
  thresholds (`TrivialSkillLineRankLow/High`) plus `NumSkillUps`. Cost per expected skill point = cost of goods
  minus resale value, divided by the chance of a point. Plan the cheapest route to max skill. Classic chance
  curves (orange 100%, yellow high, green low, grey 0) are a community model; label them as estimates.
- **Recipe payback.** A recipe sold by a vendor or found on the AH costs X; profit per craft P and a realistic
  crafts per week give the payback period.
- **Daily cooldowns** (transmutes, cloth specials): value = profit per cooldown × uses per week.
  `C_TradeSkillUI.GetRecipeCooldown` (runtime-only) reports them.

## Portfolio and accounting
- **Inventory valuation.** Bags and bank at mark-to-market (fair value) and at liquidation value (vendor floor),
  side by side; the gap is the market risk you hold.
- **Sales ledger.** Read AH invoices at the mailbox (`GetInboxInvoiceInfo`): realized revenue, the cut, deposits,
  and sell-through by item. It replaces the default `p` with measured sell-through and calibrates the cut.
- **Budget allocation.** With gold G (`GetMoney()`), pick crafts greedily by ROI, each capped by its batch limit
  (risk-and-recommendation.md) until G runs out. It's a fractional knapsack; good enough and explainable.
- **Diversify.** Don't put the whole budget into one market; saturation risk dominates small AHs.

## Data you can't get (don't pretend)
- Other players' completed sales (no region data on Forever; a ledger only covers your own sales).
- Server-side vendor inventories (only what the player sees at merchants).
- Drop rates and disenchant tables (server-side; community numbers must be labeled as estimates).
