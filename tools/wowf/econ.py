"""Reference implementation of BuffettForever's crafting economics, written from the wowf-economics
references (price-estimation.md, crafting-economics.md, risk-and-recommendation.md) apart from the
addon's Lua, so the two can check each other.

  python tools/wowf/cli.py econ vectors [--out PATH]   write BuffettForever/Economics/EvaluatorVectors.lua:
                                                       branch scenarios computed here, which /bf selftest
                                                       replays against the Lua evaluator in game
  python tools/wowf/cli.py econ check [--client K]     replay the last /bf eval (BuffettForeverDB.diag.eval
                                                       in SavedVariables) here and report every difference

Contexts mirror the Lua ones: dicts keyed by item ID (vendorBuy, vendorSell, sellPrice, ladder, recipeFor,
owned, deposit, saleChance, priceInfo) plus settings. A missing key, None and Lua's false all mean "unknown";
0 is a real value (it is truthy in Lua), so every test here is "is not None", never truthiness.
"""
import argparse
import math
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import config  # noqa: E402

GRADES = "ABCD"
GRADE_RANK = {"A": 1, "B": 2, "C": 3, "D": 4}
MAX_DEPTH = 3
DEFAULT_SETTINGS = {"cut": 0.05, "saleChance": 0.5, "margin": 0.20, "minProfit": 1000, "minGrade": "C",
                    "ownedPolicy": "opportunity"}
SALE_MIN = 0.05            # a sale chance never drops below this (deposit loss = deposit x 19 at most)
MARKET_WEIGHT = 2          # pseudo-units of the default behind your rate over all items
ITEM_WEIGHT = 5            # pseudo-units of that rate behind one item's own record
CUT_MIN_SALES, CUT_MIN_COPPER = 3, 10000   # invoices, and their total, before the measured cut counts


# ---------------------------------------------------------------- price math

def cost_to_buy(ladder, qty):
    """Walk a flat [price, qty, ...] ladder. Returns (cost, filled, units_available)."""
    need, cost = qty, 0.0
    for i in range(0, len(ladder), 2):
        take = min(need, ladder[i + 1])
        cost += take * ladder[i]
        need -= take
        if need <= 0:
            return cost, True, qty
    return cost, False, qty - need


def fair_value(history, today, half_life=3, window=14):
    num = den = 0.0
    for day, v in history.items():
        age = today - day
        if 0 <= age < window:
            w = 0.5 ** (age / half_life)
            num += w * v
            den += w
    return num / den if den else None


def ah_net(price, cut=0.05, deposit=0, p=0.5):
    if price is None:
        return None
    return price * (1 - cut) - deposit * (1 - p) / p


def liquidation(vendor, net):
    if vendor is not None and net is not None:
        return max(vendor, net)
    return net if net is not None else vendor


def sale_chance(sold, expired, prior=0.5, weight=0):
    """Units sold / (sold + expired), pulled toward prior by weight pseudo-units, kept in [SALE_MIN, 1]."""
    sold, expired = sold or 0, expired or 0
    n = sold + expired + weight
    if n <= 0:
        return prior
    return max(SALE_MIN, min(1.0, (sold + weight * prior) / n))


def item_sale_chance(sold, expired, market_sold, market_expired, default=0.5):
    """One item's sale chance from your sales ledger: its own record, pulled toward your rate over all items
    (which is pulled toward the default). Cancelled auctions count neither way."""
    market = sale_chance(market_sold, market_expired, default, MARKET_WEIGHT)
    return sale_chance(sold, expired, market, ITEM_WEIGHT)


def measured_cut(cut_total, bid_total, sales):
    """The house cut from seller invoices (total cut / total sales), or None until there are enough of them."""
    if (sales or 0) < CUT_MIN_SALES or (bid_total or 0) < CUT_MIN_COPPER:
        return None
    rate = cut_total / bid_total
    return rate if 0 <= rate < 0.5 else None


def roi(profit, cogs):
    if profit is None or cogs is None or cogs <= 0:
        return None
    return profit / cogs


def acquire(item, qty, ctx, depth=0, visiting=None):
    """Cheapest (cost, source) for qty of item: vendor, AH ladder (only if it fills), or a known recipe."""
    visiting = set() if visiting is None else visiting
    best = source = None
    unit = ctx["vendorBuy"].get(item)
    if unit is not None:
        best, source = unit * qty, "vendor"
    ladder = ctx["ladder"].get(item)
    if ladder is not None:
        cost, filled, _ = cost_to_buy(ladder, qty)
        if filled and (best is None or cost < best):
            best, source = cost, "ah"
    recipe = ctx["recipeFor"].get(item)
    if recipe is not None and depth < MAX_DEPTH and item not in visiting:
        visiting.add(item)
        crafts = math.ceil(qty / recipe["yield"])
        total = 0.0
        regs = recipe["reagents"]
        for i in range(0, len(regs), 2):
            c, _ = acquire(regs[i], regs[i + 1] * crafts, ctx, depth + 1, visiting)
            if c is None:
                total = None
                break
            total += c
        visiting.discard(item)
        if total is not None and (best is None or total < best):
            best, source = total, "craft"
    return best, source


def volatility(history, today, window=14):
    vals = [v for day, v in history.items() if 0 <= today - day < window]
    if not vals:
        return None, None
    mean = sum(vals) / len(vals)
    if mean <= 0:
        return mean, None
    var = sum((v - mean) ** 2 for v in vals) / len(vals)
    return mean, math.sqrt(var) / mean


def grade(age, days, observations, cv, listed, need):
    """Confidence grade (risk-and-recommendation.md): the worst of age, days observed, volatility, depth."""
    if age is None:
        return "D"
    g = 1
    if age >= 7 * 86400:
        g = max(g, 4)
    elif age >= 48 * 3600:
        g = max(g, 3)
    elif age >= 24 * 3600:
        g = max(g, 2)
    if (observations or 0) <= 1:
        g = max(g, 4)
    elif days >= 5:
        pass
    elif days >= 3:
        g = max(g, 2)
    else:
        g = max(g, 3)
    if cv is not None:
        if cv >= 0.60:
            g = max(g, 4)
        elif cv >= 0.30:
            g = max(g, 3)
        elif cv >= 0.15:
            g = max(g, 2)
    listed = listed or 0
    if need is not None:
        if listed < need:
            g = max(g, 4)
        elif listed < 2 * need:
            g = max(g, 2)
    elif listed <= 0:
        g = max(g, 4)
    return GRADES[g - 1]


# ---------------------------------------------------------------- the evaluator

def _grade_for(ctx, item, need):
    info = ctx["priceInfo"].get(item)
    if info is None:
        return "D"
    return grade(info.get("age"), info.get("days"), info.get("observations"), info.get("cv"), info.get("listed"), need)


def _ah_unit(ctx, item):
    """What one unit nets on the AH with the item's deposit and sale chance, floored at 0: a listing that
    loses more in deposits than it earns is worth nothing there. None when there's no AH price."""
    s = ctx["settings"]
    p = ctx.get("saleChance", {}).get(item)
    net = ah_net(ctx["sellPrice"].get(item), s["cut"], ctx["deposit"].get(item) or 0,
                 p if p is not None else s["saleChance"])
    return None if net is None else max(0.0, net)


def _liquidation(ctx, item):
    vendor = ctx["vendorSell"].get(item)
    net = _ah_unit(ctx, item)
    return liquidation(vendor, net), net is not None and (vendor is None or net > vendor)


def evaluate(recipe, crafts, ctx):
    """recipe: {recipeID, output, count, bop, reagents: [(itemID, count), ...]}. Mirrors Evaluator.Evaluate."""
    s = ctx["settings"]
    r = {"crafts": crafts, "units": recipe["count"] * crafts, "lines": [], "warnings": [], "reasons": []}
    cogs = liq_total = 0.0
    complete, worst, owned_any = True, 1, False

    def note(g):
        nonlocal worst
        worst = max(worst, GRADE_RANK[g])

    for item, count in recipe["reagents"]:
        need = count * crafts
        line = {"itemID": item, "need": need, "owned": 0, "ownedCost": 0.0, "buyCost": 0.0, "source": None}
        unit_liq, from_ah = _liquidation(ctx, item)
        owned = min(need, ctx["owned"].get(item) or 0)
        if owned > 0:
            owned_any = True
            line["owned"] = owned
            policy = s["ownedPolicy"]
            if policy == "free":
                unit = 0
            elif policy == "replacement":
                cost, _ = acquire(item, owned, ctx)
                unit = cost / owned if cost is not None else None
            else:
                unit = unit_liq
                if unit is not None and from_ah:
                    note(_grade_for(ctx, item, None))
            if unit is not None:
                line["ownedCost"] = owned * unit
            else:
                r["warnings"].append(["unknownValue", item])
        rest = need - owned
        line["rest"] = rest
        if rest > 0:
            cost, source = acquire(item, rest, ctx)
            if cost is not None:
                line["buyCost"], line["source"] = cost, source
                if source == "ah":
                    note(_grade_for(ctx, item, rest))
            else:
                complete = False
                ladder = ctx["ladder"].get(item)
                if ladder is not None:
                    _, _, available = cost_to_buy(ladder, rest)
                    r["warnings"].append(["cantFill", item, available, rest])
                else:
                    r["warnings"].append(["noPrice", item])
        line["cost"] = line["ownedCost"] + line["buyCost"]
        cogs += line["cost"]
        liq_total += need * (unit_liq or 0)
        r["lines"].append(line)

    out = recipe["output"]
    vendor_unit = ctx["vendorSell"].get(out)
    r["vendorExit"] = vendor_unit * r["units"] if vendor_unit is not None else None
    r["ahExit"] = r["ahUnit"] = None
    if not recipe["bop"]:
        unit = _ah_unit(ctx, out)
        if unit is not None:
            r["ahUnit"], r["ahExit"] = unit, unit * r["units"]
    ah, vend = r["ahExit"], r["vendorExit"]
    r["best"] = r["bestSource"] = None
    r["underMargin"] = False
    if ah is not None and (vend is None or ah >= vend * (1 + s["margin"])):
        r["best"], r["bestSource"] = ah, "ah"
        note(_grade_for(ctx, out, None))
    elif vend is not None:
        r["best"], r["bestSource"] = vend, "vendor"
        r["underMargin"] = ah is not None and ah > vend

    r["cogs"], r["complete"], r["liquidation"] = cogs, complete, liq_total
    r["profit"] = r["roi"] = r["valueAdded"] = None
    if r["best"] is not None and complete:
        r["profit"] = r["best"] - cogs
        r["roi"] = roi(r["profit"], cogs)
    if r["best"] is not None:
        r["valueAdded"] = r["best"] - liq_total
    r["grade"] = GRADES[worst - 1]

    reasons = r["reasons"]
    if not complete:
        reasons.append("noReagentPrice")
    if r["best"] is None:
        reasons.append("noExit")
    if r["profit"] is not None:
        if r["profit"] < 0:
            reasons.append("loss")
        else:
            if r["roi"] is not None and r["roi"] < s["margin"]:
                reasons.append("roiUnderMargin")
            if r["profit"] / crafts < s["minProfit"]:
                reasons.append("underMinProfit")
    if GRADE_RANK[r["grade"]] > GRADE_RANK[s["minGrade"]]:
        reasons.append("thinData")
    if (owned_any and r["valueAdded"] is not None and r["valueAdded"] < s["margin"] * liq_total
            and r["profit"] is not None and r["profit"] >= 0):
        reasons.append("sellRaw")
    r["recommended"] = not reasons
    return r


def rank_key(r):
    """Sort key matching Evaluator.Rank: recommended first, ROI high to low (nothing spent = infinite,
    unknown profit = last), then profit, then recipe ID."""
    if r["profit"] is None:
        roi_key = -math.inf
    else:
        roi_key = r["roi"] if r["roi"] is not None else math.inf
    profit = r["profit"] if r["profit"] is not None else -math.inf
    return (not r["recommended"], -roi_key, -profit, r["recipeID"])


# ---------------------------------------------------------------- branch scenarios -> Lua vectors

def _info(age=3600, days=5, observations=6, cv=0.10, listed=1000):
    return {"age": age, "days": days, "observations": observations, "cv": cv, "listed": listed}


def _ctx(settings=None, **tables):
    ctx = {k: {} for k in ("vendorBuy", "vendorSell", "sellPrice", "ladder", "recipeFor", "owned", "deposit",
                           "saleChance", "priceInfo")}
    ctx.update(tables)
    ctx["settings"] = dict(DEFAULT_SETTINGS, **(settings or {}))
    return ctx


def _recipe(rid, output, count, reagents, bop=False):
    return {"recipeID": rid, "output": output, "count": count, "bop": bop, "reagents": reagents}


LINEN, BOLT, COPPER, TIN, BRONZE, BRACERS = 2589, 2996, 2840, 3576, 2841, 2671


def scenarios():
    """(name, recipe, crafts, ctx): every branch of the evaluator at least once."""
    linen_ladder = [950, 20, 1000, 40, 1100, 100]
    bolt = _recipe(2963, BOLT, 1, [(LINEN, 2)])

    def bolt_ctx(settings=None, **over):
        t = dict(vendorSell={LINEN: 13, BOLT: 40}, sellPrice={LINEN: 950, BOLT: 2900}, ladder={LINEN: linen_ladder},
                 owned={LINEN: 6}, priceInfo={LINEN: _info(), BOLT: _info()})
        t.update(over)
        return _ctx(settings, **t)

    bronze = _recipe(2659, BRONZE, 2, [(COPPER, 1), (TIN, 1)])
    bracers = _recipe(2671, BRACERS, 1, [(BRONZE, 4)])
    smelt = {"yield": 2, "reagents": [COPPER, 1, TIN, 1]}
    out = [
        ("BOLT-UNDER-MIN", bolt, 10, bolt_ctx()),                          # 8.8s per craft < 10s minimum
        ("BOLT-RECOMMENDED", bolt, 10, bolt_ctx({"minProfit": 500})),
        ("BOLT-DEPOSIT", bolt, 10, bolt_ctx({"minProfit": 500}, deposit={BOLT: 60})),
        ("BOLT-REPLACEMENT", bolt, 10, bolt_ctx({"minProfit": 500, "ownedPolicy": "replacement"})),
        ("BOLT-CANT-FILL", bolt, 70, bolt_ctx(ladder={LINEN: [950, 20, 1000, 40]})),   # 134 needed, 60 listed
        ("BOLT-THIN-DATA", bolt, 10, bolt_ctx({"minProfit": 500}, priceInfo={LINEN: _info(), BOLT: _info(observations=1, days=1)})),
        ("BOLT-STALE-C", bolt, 10, bolt_ctx({"minProfit": 500}, priceInfo={LINEN: _info(), BOLT: _info(age=50 * 3600)})),
        ("BOLT-UNDER-MARGIN", bolt, 10, bolt_ctx(sellPrice={LINEN: 950, BOLT: 46})),   # AH 43.7c vs vendor 40c
        ("BOLT-BOP", _recipe(2963, BOLT, 1, [(LINEN, 2)], bop=True), 10, bolt_ctx()),
        ("BOLT-LOSS", bolt, 10, bolt_ctx(sellPrice={LINEN: 950, BOLT: 1500})),
        ("BOLT-NO-EXIT", bolt, 10, bolt_ctx(vendorSell={LINEN: 13}, sellPrice={LINEN: 950})),
        ("BOLT-NO-REAGENT-PRICE", bolt, 10, bolt_ctx(ladder={}, owned={})),
        ("BOLT-ROI-UNDER-MARGIN", bolt, 1, bolt_ctx({"minProfit": 0}, owned={}, sellPrice={LINEN: 950, BOLT: 2100})),
        ("BOLT-FREE-SELL-RAW", bolt, 3, bolt_ctx({"ownedPolicy": "free", "minProfit": 0},
                                                 sellPrice={LINEN: 950, BOLT: 2000})),
        ("BOLT-FREE-GOOD", bolt, 3, bolt_ctx({"ownedPolicy": "free", "minProfit": 0},
                                             sellPrice={LINEN: 950, BOLT: 4000})),
        ("BRONZE-VENDOR", bronze, 1, _ctx({"minProfit": 0}, vendorSell={COPPER: 10, TIN: 35, BRONZE: 50},
                                          owned={COPPER: 1, TIN: 1})),
        ("BRONZE-PARTIAL", bronze, 3, _ctx({"minProfit": 0}, vendorSell={COPPER: 10, TIN: 35, BRONZE: 50},
                                           sellPrice={COPPER: 400, BRONZE: 900}, ladder={COPPER: [400, 50]},
                                           vendorBuy={TIN: 90}, owned={COPPER: 1},
                                           priceInfo={COPPER: _info(age=30 * 3600), BRONZE: _info()})),
        ("BRACERS-MAKE-OR-BUY", bracers, 1, _ctx(vendorSell={BRACERS: 100}, sellPrice={BRACERS: 1500},
                                                 ladder={BRONZE: [80, 10]}, vendorBuy={COPPER: 60, TIN: 90},
                                                 recipeFor={BRONZE: smelt}, priceInfo={BRACERS: _info()})),
        ("CYCLE-GUARD", _recipe(1, 10, 1, [(11, 1)]), 1, _ctx(vendorSell={10: 500}, vendorBuy={11: 100},
                                                              recipeFor={11: {"yield": 1, "reagents": [12, 1]},
                                                                         12: {"yield": 1, "reagents": [11, 1]}})),
        # 21 <- 22 <- 23 <- 24 <- 25 (1c at a vendor): item 24 would need a 4th recipe level, past the
        # depth limit of 3, so 23, 22 and 21 can't be crafted and 21 comes from the vendor at 900.
        ("DEPTH-LIMIT", _recipe(2, 20, 1, [(21, 1)]), 1,
         _ctx(vendorSell={20: 1000}, vendorBuy={21: 900, 25: 1},
              recipeFor={21: {"yield": 1, "reagents": [22, 1]}, 22: {"yield": 1, "reagents": [23, 1]},
                         23: {"yield": 1, "reagents": [24, 1]}, 24: {"yield": 1, "reagents": [25, 1]}})),
        # The sales ledger (M4): the item's own sale chance and deposit, the measured cut.
        ("BOLT-SALE-CHANCE", bolt, 10, bolt_ctx({"minProfit": 500}, deposit={BOLT: 60}, saleChance={BOLT: 0.8})),
        ("BOLT-OWNED-LOW-P", bolt, 10, bolt_ctx({"minProfit": 500}, deposit={LINEN: 100}, saleChance={LINEN: 0.25})),
        ("BOLT-CUT-15", bolt, 10, bolt_ctx({"minProfit": 500, "cut": 0.15})),
        # Deposits lost on unsold listings outweigh the price: the AH nets 0, so the vendor wins (or, with
        # no vendor, the AH's 0 is the best there is and the batch loses its cost).
        ("BOLT-UNSOLD", bolt, 10, bolt_ctx(deposit={BOLT: 400}, saleChance={BOLT: 0.1})),
        ("BOLT-UNSOLD-NO-VENDOR", bolt, 10, bolt_ctx(vendorSell={LINEN: 13}, deposit={BOLT: 400},
                                                     saleChance={BOLT: 0.1})),
        # An owned reagent no vendor buys whose AH listing would lose money is worth 0, not less.
        ("OWNED-WORTHLESS", _recipe(3, 30, 1, [(31, 1)]), 1,
         _ctx({"minProfit": 0}, vendorSell={30: 500}, sellPrice={31: 100}, owned={31: 1}, deposit={31: 100},
              saleChance={31: 0.1}, priceInfo={31: _info()})),
    ]
    return out


def to_lua(value, indent=0):
    pad = "    " * indent
    if value is None:
        return "nil"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, (int, float)):
        if isinstance(value, float) and math.isinf(value):
            return "math.huge" if value > 0 else "-math.huge"
        return repr(value) if isinstance(value, float) else str(value)
    if isinstance(value, str):
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'
    if isinstance(value, (list, tuple)):
        if not value:
            return "{}"
        inner = ", ".join(to_lua(v, indent + 1) for v in value)
        return "{ " + inner + " }"
    if isinstance(value, dict):
        if not value:
            return "{}"
        parts = []
        for k in sorted(value, key=lambda x: (isinstance(x, str), x)):
            v = value[k]
            if v is None:
                continue
            key = f"[{k}]" if isinstance(k, int) else k
            parts.append(f"{pad}    {key} = {to_lua(v, indent + 1)},")
        return "{\n" + "\n".join(parts) + f"\n{pad}}}"
    raise TypeError(f"can't write {type(value)} to Lua")


def _lua_recipe(recipe):
    return {"recipeID": recipe["recipeID"], "output": recipe["output"], "count": recipe["count"], "bop": recipe["bop"],
            "reagents": [{"itemID": i, "count": c} for i, c in recipe["reagents"]]}


def _expect(r):
    return {
        "cogs": r["cogs"], "vendorExit": r["vendorExit"], "ahExit": r["ahExit"], "best": r["best"],
        "bestSource": r["bestSource"], "profit": r["profit"], "roi": r["roi"], "valueAdded": r["valueAdded"],
        "grade": r["grade"], "recommended": r["recommended"], "reasons": ",".join(r["reasons"]),
        "sources": ",".join(line["source"] or "-" for line in r["lines"]),
        "warnings": ",".join(w[0] for w in r["warnings"]),
    }


def vectors():
    out = []
    for name, recipe, crafts, ctx in scenarios():
        r = evaluate(recipe, crafts, ctx)
        out.append({"name": name, "crafts": crafts, "recipe": _lua_recipe(recipe), "ctx": ctx, "expect": _expect(r)})
    return out


def emit_vectors_lua(vecs, generated):
    lines = [
        "local addonName, ns = ...",
        "",
        "-- GENERATED by tools/wowf/econ.py (econ vectors). Do not edit by hand.",
        f"-- Generated {generated}. Branch scenarios for Economics/Evaluator.lua, with the results computed by",
        "-- the Python reference implementation; /bf selftest replays them against the Lua evaluator.",
        "",
        "ns.EvaluatorVectors = {",
    ]
    for v in vecs:
        lines.append("    " + to_lua(v, 1) + ",")
    lines.append("}")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------- econ check: replay a /bf eval snapshot

def _unfalse(v):
    return None if v is False else v


def _key(k):
    """An item ID key: an int from savedvars.load_sv, or "[2589]" from its JSON export."""
    return int(str(k).strip("[]"))


def context_from_snapshot(snap):
    """The Lua context saved by /bf eval (diag.eval.ctx) as a Python context."""
    c = snap.get("ctx") or {}
    ctx = {}
    for name in ("vendorBuy", "vendorSell", "sellPrice", "owned", "deposit", "saleChance"):
        ctx[name] = {_key(k): _unfalse(v) for k, v in (c.get(name) or {}).items() if _unfalse(v) is not None}
    ctx["ladder"] = {_key(k): list(v) for k, v in (c.get("ladder") or {}).items() if _unfalse(v) is not None}
    ctx["priceInfo"] = {_key(k): dict(v) for k, v in (c.get("priceInfo") or {}).items() if _unfalse(v) is not None}
    ctx["recipeFor"] = {}
    for k, v in (c.get("recipeFor") or {}).items():
        if _unfalse(v) is not None:
            ctx["recipeFor"][_key(k)] = {"yield": v["yield"], "reagents": list(v["reagents"])}
    ctx["settings"] = dict(DEFAULT_SETTINGS, **(snap.get("settings") or {}))
    return ctx


MONEY_FIELDS = ("cogs", "vendorExit", "ahExit", "best", "profit", "valueAdded")


def compare(lua, py):
    """Differences between a Lua result (from the snapshot) and the Python result, as strings."""
    diffs = []

    def num(name, a, b, tol):
        if (a is None) != (b is None) or (a is not None and abs(a - b) > tol):
            diffs.append(f"{name}: Lua {a} vs Python {b}")

    for f in MONEY_FIELDS:
        num(f, _unfalse(lua.get(f)), py[f], 0.01)
    num("roi", _unfalse(lua.get("roi")), py["roi"], 1e-6)
    for f in ("bestSource", "grade"):
        if _unfalse(lua.get(f)) != py[f]:
            diffs.append(f"{f}: Lua {lua.get(f)} vs Python {py[f]}")
    if bool(lua.get("recommended")) != py["recommended"]:
        diffs.append(f"recommended: Lua {lua.get('recommended')} vs Python {py['recommended']}")
    lr = ",".join(_unfalse(lua.get("reasons")) or [])
    if lr != ",".join(py["reasons"]):
        diffs.append(f"reasons: Lua {lr} vs Python {','.join(py['reasons'])}")
    ls = ",".join(_unfalse(lua.get("sources")) or [])
    ps = ",".join(line["source"] or "-" for line in py["lines"])
    if ls != ps:
        diffs.append(f"sources: Lua {ls} vs Python {ps}")
    return diffs


def cap_violations(snap):
    """Items a vendor sells whose saved AH sell price is above the vendor's price: the live context
    caps it (nobody pays more on the AH than a vendor charges). Returns [(itemID, sellPrice, vendor)]."""
    ctx = context_from_snapshot(snap)
    out = []
    for item, price in ctx["sellPrice"].items():
        vendor = ctx["vendorBuy"].get(item)
        if vendor is not None and price > vendor + 0.01:
            out.append((item, price, vendor))
    return out


def check_snapshot(snap, names=None):
    """Replay every recipe of a /bf eval snapshot. Returns (checked, mismatches [(recipeID, diffs)], order_ok)."""
    ctx = context_from_snapshot(snap)
    mismatches, py_results = [], []
    results = snap.get("results") or []
    for res in results:
        recipe = {"recipeID": res["recipeID"], "output": res["output"], "count": res["count"], "bop": bool(res.get("bop")),
                  "reagents": [(res["reagents"][i], res["reagents"][i + 1]) for i in range(0, len(res["reagents"]), 2)]}
        py = evaluate(recipe, res["crafts"], ctx)
        py["recipeID"] = res["recipeID"]
        py_results.append(py)
        diffs = compare(res, py)
        if diffs:
            mismatches.append((res["recipeID"], diffs))
    order_lua = [res["recipeID"] for res in results]
    order_py = [r["recipeID"] for r in sorted(py_results, key=rank_key)]
    return len(results), mismatches, order_lua == order_py


def _money(c):
    if c is None:
        return "?"
    sign = "-" if c < 0 else ""
    c = int(round(abs(c)))
    g, s, cp = c // 10000, (c // 100) % 100, c % 100
    return sign + (f"{g}g {s:02d}s {cp:02d}c" if g else f"{s}s {cp:02d}c" if s else f"{cp}c")


def report(snap, items, spells, top=15):
    """A readable table of a snapshot's ranked results, with the reasons and grades tallied."""
    results = snap.get("results") or []
    lines = []
    recommended = sum(1 for r in results if r.get("recommended"))
    lines.append(f"{len(results)} recipes, {recommended} recommended")
    tally, grades = {}, {}
    for r in results:
        for key in _unfalse(r.get("reasons")) or []:
            tally[key] = tally.get(key, 0) + 1
        grades[r.get("grade")] = grades.get(r.get("grade"), 0) + 1
    lines.append("  reasons: " + ", ".join(f"{k} {v}" for k, v in sorted(tally.items(), key=lambda kv: -kv[1])))
    lines.append("  grades: " + ", ".join(f"{k} {grades[k]}" for k in sorted(grades)))
    for i, r in enumerate(results[:top], 1):
        roi_v = _unfalse(r.get("roi"))
        roi_text = f"{roi_v * 100:.0f}%" if roi_v is not None else "n/a"
        exit_text = f"{r.get('bestSource') or '-'} {_money(_unfalse(r.get('best')))}"
        why = "" if r.get("recommended") else "  [" + ",".join(_unfalse(r.get("reasons")) or []) + "]"
        units = r.get("count", 1) * r.get("crafts", 1)
        name = items.get(r.get("output"), spells.get(r.get("recipeID"), "?"))
        lines.append(f"  {i:2}. {name} x{units}: cost {_money(r.get('cogs'))}, {exit_text}, "
                     f"profit {_money(_unfalse(r.get('profit')))}, ROI {roi_text}, grade {r.get('grade')}{why}")
    return "\n".join(lines)


def _snapshots(cfg, client=None):
    import savedvars
    out = []
    for key, c in config.discover_clients(cfg).items():
        if client and key != client:
            continue
        for scope, _, path in savedvars.find_sv_files(c["dir"], "BuffettForever"):
            if scope == "account":
                snap = ((savedvars.load_sv(path).get("BuffettForeverDB") or {}).get("diag") or {}).get("eval")
                if isinstance(snap, dict):
                    out.append((key, path, snap))
    return out


def _names():
    """Item and spell names from the recipe tool's cached game tables, if any (for readable reports)."""
    try:
        import recipe_catalog as rc
        t = rc.read_tables(rc.DEFAULT_BUILD)
        return ({int(r["ID"]): r["Display_lang"] for r in t["ItemSparse"]},
                {int(r["ID"]): r["Name_lang"] for r in t["SpellName"]})
    except Exception:
        return {}, {}


def main(argv):
    p = argparse.ArgumentParser(prog="wowf econ")
    p.add_argument("action", choices=["vectors", "check"])
    p.add_argument("--out", help="vectors: output path (default BuffettForever/Economics/EvaluatorVectors.lua)")
    p.add_argument("--client", help="check: only this client (e.g. beta)")
    p.add_argument("--top", type=int, default=0, help="check: also print the N best-ranked recipes with names")
    a = p.parse_args(argv)
    cfg = config.load()
    if a.action == "vectors":
        out = a.out or os.path.join(cfg["_root"], "BuffettForever", "Economics", "EvaluatorVectors.lua")
        vecs = vectors()
        with open(out, "w", encoding="utf-8", newline="\n") as f:
            f.write(emit_vectors_lua(vecs, time.strftime("%Y-%m-%d")))
        print(f"wrote {out}: {len(vecs)} scenarios")
        return 0
    found = _snapshots(cfg, a.client)
    if not found:
        print("no /bf eval snapshot found: run /bf eval in game, then /reload")
        return 1
    items, spells = _names()
    status = 0
    for key, path, snap in found:
        checked, mismatches, order_ok = check_snapshot(snap)
        when = time.strftime("%Y-%m-%d %H:%M", time.localtime(snap.get("t") or 0))
        print(f"{key}: /bf eval from {when} (build {snap.get('build')}): {checked} recipes replayed, "
              f"{checked - len(mismatches)} match, {len(mismatches)} differ; ranking {'matches' if order_ok else 'DIFFERS'}")
        for rid, diffs in mismatches[:20]:
            print(f"  {rid} {spells.get(rid, '')}: " + "; ".join(diffs))
        caps = cap_violations(snap)
        if caps:
            print(f"  vendor cap broken for {len(caps)} items: " + ", ".join(
                f"{items.get(i, i)} AH {p:g} > vendor {v:g}" for i, p, v in caps[:10]))
        else:
            print("  vendor cap holds: no AH price above what a vendor charges")
        if mismatches or not order_ok or caps:
            status = 1
        recipes = {}
        for res in snap.get("results") or []:
            regs = res["reagents"]
            for i in range(0, len(regs), 2):
                recipes.setdefault(regs[i], 0)
                recipes[regs[i]] += 1
        for entry in snap.get("tray") or []:
            iid = entry.get("itemID")
            print(f"  tray: {iid} {items.get(iid, '?')} x{entry.get('qty')}: used by {recipes.get(iid, 0)} of these recipes")
        if a.top:
            print(report(snap, items, spells, a.top))
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
