# Price estimation: from scans to prices

All prices are copper per **unit**. A replicate row's `buyoutPrice` covers the whole stack, so
unit price = `buyoutPrice / count`; rows with `buyoutPrice == 0` are bid-only and are skipped. The scan side
(how to read listings) is in wowf-addon-dev auction-house.md.

## Four prices, four jobs
| Price | Definition | Use it for |
|---|---|---|
| **Min buyout** | the cheapest unit price in the latest scan | showing the floor; spotting bargains. Fragile: one troll or one-unit listing moves it |
| **Market value** (per scan) | the robust estimator below | what the item "trades at" right now |
| **Fair value** | decay-weighted history of daily market values | decisions that shouldn't swing with one scan |
| **Cost to buy Q** | walking the price ladder | what Q units actually cost (depth matters) |

## Market value (per scan): lower-quantile trimmed mean
1. Sort listings by unit price.
2. Take listings from the cheapest until they cover **15%** of the listed quantity. Keep adding while the total is
   under **30%** and the next price is no more than **20%** above the previous one.
3. Take the quantity-weighted mean and standard deviation of that window.
4. Drop listings more than **2σ** from the mean (troll 1c listings, fat-finger highs), then re-take the mean.

Why: buyers buy the cheapest units first, so the market lives at the low end; quantity weighting stops a one-unit
listing from dominating; the 30% cap and the jump stop keep high asks out; the 2σ trim handles outliers inside
the window. It's a standard robust-statistics approach and needs nothing but the scan.

```lua
local addonName, ns = ...
local Econ = ns.Econ or {}
ns.Econ = Econ

local function WeightedStats(listings, set)
    local w, s = 0, 0
    for _, i in ipairs(set) do
        w = w + listings[2 * i]
        s = s + listings[2 * i - 1] * listings[2 * i]
    end
    local mean = s / w
    local v = 0
    for _, i in ipairs(set) do
        local d = listings[2 * i - 1] - mean
        v = v + d * d * listings[2 * i]
    end
    return mean, math.sqrt(v / w)
end

-- listings: flat { price1, qty1, price2, qty2, ... } in any order (as a scan collects them).
-- Returns marketValue, minBuyout, totalQuantity, auctionCount; nil for no listings.
function Econ.MarketValue(listings)
    local n = #listings / 2
    if n < 1 then return nil end
    local order = {}
    for i = 1, n do order[i] = i end
    table.sort(order, function(a, b) return listings[2 * a - 1] < listings[2 * b - 1] end)
    local total = 0
    for i = 1, n do total = total + listings[2 * i] end
    local lowCap, highCap = total * 0.15, total * 0.30
    local window, cum, prev = {}, 0, nil
    for _, i in ipairs(order) do
        local p, q = listings[2 * i - 1], listings[2 * i]
        if cum >= lowCap and (cum >= highCap or (prev and p > prev * 1.2)) then break end
        window[#window + 1] = i
        cum = cum + q
        prev = p
    end
    local mean, sd = WeightedStats(listings, window)
    local kept = {}
    for _, i in ipairs(window) do
        if math.abs(listings[2 * i - 1] - mean) <= 2 * sd then kept[#kept + 1] = i end
    end
    if #kept > 0 then mean = WeightedStats(listings, kept) end
    return mean, listings[2 * order[1] - 1], total, n
end
```

## Fair value: decay-weighted history
Keep one value per item per day (the mean of that day's scans). Weight each day by its age with a **half-life**
instead of a classic recursive EMA: gaps (days with no scan) then need no special handling.

```lua
-- history: { [day] = value }, day = math.floor(GetServerTime() / 86400)
function Econ.FairValue(history, today, halfLife, window)
    halfLife, window = halfLife or 3, window or 14
    local num, den = 0, 0
    for day, v in pairs(history) do
        local age = today - day
        if age >= 0 and age < window then
            local w = 0.5 ^ (age / halfLife)
            num = num + w * v
            den = den + w
        end
    end
    if den == 0 then return nil end   -- nothing recent enough: unknown, not zero
    return num / den
end
```
A half-life `h` matches an EMA with α = 1 − 0.5^(1/h): h = 3 days ≈ α 0.21 ≈ a 9-day EMA.

## Cost to buy Q units: the price ladder
Keep the latest scan's ladder per item: unit price levels, cheapest first, with quantities (merge equal prices;
~8 levels or enough to cover a few stacks is plenty). BuffettForever keeps 8 levels, adds more until 100 units are
covered, and stops at 16. On the beta that's median 2 levels, p90 8. Buying Q walks it:

```lua
-- ladder: flat { price1, qty1, price2, qty2, ... } sorted by price ascending.
-- Returns cost, filled (boolean), unitsAvailable.
function Econ.CostToBuy(ladder, qty)
    local need, cost = qty, 0
    for i = 1, #ladder, 2 do
        local take = math.min(need, ladder[i + 1])
        cost = cost + take * ladder[i]
        need = need - take
        if need <= 0 then return cost, true, qty end
    end
    return cost, false, qty - need
end
```
This is what makes multiples cost the right amount: 8 units may cost 9.50s each while 70 average 10s.
When the ladder can't fill Q, say so ("only 160 listed"); don't extrapolate silently.

## Which price where (conservative by default)
- **Buying an input:** `CostToBuy` from the latest ladder when it's fresh; otherwise the fair value with a stale
  warning. Never price a purchase at min buyout alone.
- **Selling an output:** the lower of the latest market value and the latest min buyout (you must undercut
  the cheapest listing to sell soon); the fair value when the scan is stale.
- **Freshness:** under 24 h, use the latest scan; 24–48 h, blend (or warn); over 48 h, fall back to fair value and
  lower the confidence grade; nothing in 14 days means **unknown**.

## Storage shape (SavedVariables)
```lua
-- BuffettForeverDB.markets[marketKey].items[itemID] =
-- { t = lastScanTime, mv = 106.25, min = 100, q = 100, n = 5,
--   ladder = "100:5,105:5,110:10,300:20",            -- top levels of the latest scan
--   h = { [20376] = "106.25:100:100:5:2", ... } }    -- day -> "mv:min:qty:n:k", pruned to 14-30 days
```
A day can hold several scans. `k` counts them, so the day's `mv` stays the mean of its scans
(`(mv * k + new) / (k + 1)`); `min` is the day's lowest, and `qty` and `n` the latest. Keep prices to 0.01 copper.
`n` (auctions) comes from full scans, one row per auction. A **commodity search returns rows grouped by unit
price** (41 rows for 295 auctions on 70425), so it has no auction count. Keep the scan's `n` and let the search update
the prices, quantity and ladder. The quantity-weighted market value is the same either way.
Pack days into strings, prune at login, and keep the file small: about 185 bytes per item plus 33 per day on
70425 (auction-house.md has the measurements and the `SAVED_VARIABLES_TOO_LARGE` note). Store aggregates only,
never every listing.

## Test vectors (computed with an independent Python implementation)
| Case | Input | Expected |
|---|---|---|
| MV-1 | (100×5, 105×5, 110×10, 300×20, 1000×60) | market 106.25, min 100, qty 100, auctions 5 (window stops at the 300 jump) |
| MV-2 | (250×3) | market 250, min 250 |
| MV-3 | (1×1, 500×20, 510×30, 520×49) | market 506, min 1 (the 1c troll is trimmed) |
| BUY-1 | ladder (950×20, 1000×40, 1100×100), Q 8 | 7600, filled |
| BUY-2 | same ladder, Q 70 | 70000, filled |
| BUY-3 | same ladder, Q 200 | 169000, not filled, 160 available |
| FAIR-1 | days {100: 100, 99: 120, 97: 80}, today 100, h 3, window 14 | ≈ 102.561 |
| FAIR-2 | days {80: 100}, today 100 | nil (unknown) |
