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
- As built (BuffettForever 0.7.0, the Vendor crafts and AH flips views):
  - **Vendor crafts** evaluate each known recipe on the context with the AH taken out (Python `vendor_context`),
    so owned reagents count at what a vendor pays. That is the certain comparison.
    - The batch is what your bags allow: every reagent a vendor (or a recipe from vendor goods) can't supply
      must be owned.
    - Flag a craft whose owned reagents would fetch more raw on the AH than crafting pays at a vendor
      (opportunity cost, less certain).
  - **AH flips** come from every listing in the full scan, with your own left out. `flip(listings, vendor_sell)`
    returns the units below the vendor price, their cost, their value at the vendor, and the cheapest and dearest.
    - The confidence follows the scan's age, because listings vanish fast: A under 15 min, B under 1 h, C under
      6 h.
    - For a commodity, buying the flip's quantity takes the cheapest units first, which are exactly these.
  - FLIP-1: listings 40c × 5, 45c × 10, 60c × 20, vendor 50c → 15 units, cost 6s 50c, worth 7s 50c, 40c to
    45c. FLIP-2: vendor price 0 → none. FLIP-3: all above → none. FLIP-4: 49.5c × 3 → 3 (half a copper counts).
  - **Buying a flip** (BuffettForever 1.0.0; gear tested on 70450):
    - Search the item first, because a scan's listings can be gone.
    - A stackable flip is one quote for every unit still below the vendor price. Refuse it unless the total stays
      under units × the vendor price (`Buy.FlipCheck`).
    - Gear goes one auction at a time, cheapest first.
    - Search again after each purchase, and drop the flip once nothing is left below the vendor price.
  - **Flips on the beta were thin** (70450, 2026-10-18). Five flips from one scan made 24c to 99c each in all, on
    76s to 3g 89s spent, so none reached the 10s minimum profit, and the view marked them not recommended. Two
    Cross Daggers bought at 38s paid 30c each at a vendor.

## Mr. Market signals
- z-score of today's market value against fair value: `z = (now − fair) / σ` over the window.
  - z < −1: inputs are cheap; stock up for planned crafts.
  - z > +1: outputs are dear; sell what you hold.
- Show signals as hints, never as orders; a thin market can produce any z.
- As built (BuffettForever 0.6.0, `Econ.MrMarket`, `Econ.Mood`; Python `mr_market`, `mood`):
  - σ is the standard deviation of the daily market values in the window, and fair is the decay-weighted fair
    value (price-estimation.md). Only with 5 or more days.
  - The mood is "cheap" or "dear" only when |z| ≥ 1 **and** the price is at least 10% from fair value, so a very
    steady item can't flag on a few copper.
  - MOOD-1: days 1000, 1100, 900, 1000, today 700 → fair 905.7, z −1.517, −22.7%: cheap.
  - MOOD-2: 1000, 1000, 1010, 990, today 1300 → z +1.75, +19.3%: dear.
  - MOOD-3: 2 days → no mood.

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
  The estimator is in crafting-economics.md ("Sale chance"), and the mail flow in wowf-addon-dev auction-house.md
  ("Sales mail and your auctions"). Built in BuffettForever 0.5.0.
- **Budget allocation.** With gold G (`GetMoney()`), pick crafts greedily by ROI, each capped by its batch limit
  (risk-and-recommendation.md) until G runs out. It's a fractional knapsack; good enough and explainable.
- **Diversify.** Don't put the whole budget into one market; saturation risk dominates small AHs.

## Data you can't get (don't pretend)
- Other players' completed sales (no region data on Forever; a ledger only covers your own sales).
- Server-side vendor inventories (only what the player sees at merchants).
- Drop rates and disenchant tables (server-side; community numbers must be labeled as estimates).
