"""Build BuffettForever's recipe and vendor data from Forever game tables (wago.tools).

  python tools/wowf/cli.py recipe-catalog fetch [--build B]          DB2 CSVs into the cache
  python tools/wowf/cli.py recipe-catalog build [--build B] [--out DIR]
  python tools/wowf/cli.py recipe-catalog show [--build B] [--item ID]
  python tools/wowf/cli.py recipe-catalog vendor-merge [--build B]   add vendor-sold reagents from
                                                                     BuffettForever's merchant harvest

Data path: SkillLine (the profession lines and their Forever child lines) -> SkillLineAbility
(Spell, MinSkillLineRank, TrivialSkillLineRankLow/High) -> SpellEffect (Effect 24 = create item:
EffectItemType, EffectBasePointsF = count, where 0 means 1) and SpellReagents (Reagent_0..7 with
ReagentCount_0..7). A recipe is kept only when its output and every reagent exist in ItemSparse
(missing items are encrypted in that build). Enchant-only spells (Effect 53) make no item and are
left out. Vendor prices come from ItemSparse BuyPrice / VendorStackCount, for the reagents listed in
data/vendor_reagents.json (which items a vendor sells is server-side; that list holds the evidence).
Only IDs and numbers are emitted; names come from the client at run time.
"""
import argparse
import collections
import csv
import json
import os
import re
import sys
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import config  # noqa: E402

RECIPE_DIR = os.path.join(config.CACHE_DIR, "recipes")
WAGO = "https://wago.tools"
UA = "wowf-tools/0.1 (+https://github.com/Typheous1979/wow-forever-workspace)"
DEFAULT_BUILD = "1.60.1.70450"
TABLES = ("SkillLine", "SkillLineAbility", "SpellEffect", "SpellReagents", "SpellName", "ItemSparse")

# Classic profession skill lines; Forever adds a child line for each (2937-2948 on 70450).
PROFESSIONS = {
    129: "First Aid", 164: "Blacksmithing", 165: "Leatherworking", 171: "Alchemy", 182: "Herbalism",
    185: "Cooking", 186: "Mining", 197: "Tailoring", 202: "Engineering", 333: "Enchanting",
    356: "Fishing", 393: "Skinning",
}
EFFECT_CREATE_ITEM = "24"
EFFECT_ENCHANT_ITEM = "53"
# IDs added after Classic: Season-of-Discovery spells (400000-1M, items 200000-250000) and Forever-new
# recipes (spells >= 1.2M, items >= 250000; 117 of their outputs were on the beta AH, 70425).
# Flagged "new": unconfirmed on Forever until known, seen in a profession window, or seen on the AH.
NEW_SPELL_ID = 400000
NEW_ITEM_ID = 200000
FLAG_NEW = 1
FLAG_BOP = 2
MAX_REAGENTS = 8

# Name hints for vendor-reagent candidates (only a review aid; evidence decides).
_VENDORISH = re.compile(r"thread|dye|vial|flux|spice|salt|bleach|\brod\b|stock|parchment|wiring|simple wood|"
                        r"spring water|milk|flour|coal|nightcrawler|apple|wire", re.I)


# ---------------------------------------------------------------- fetching

def _get(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=300) as r:
        return r.read()


def check_csv(data):
    """True for a DB2 CSV: a header row with an ID column. SkillLine and SkillLineAbility don't
    start with ID, so a startswith("ID,") check would reject them."""
    header = data.split(b"\n", 1)[0].decode("utf-8", "replace")
    return "ID" in [c.strip() for c in header.split(",")]


def csv_dir(build):
    return os.path.join(RECIPE_DIR, "csv", build)


def fetch_tables(build, log=print):
    d = csv_dir(build)
    os.makedirs(d, exist_ok=True)
    for t in TABLES:
        path = os.path.join(d, t + ".csv")
        if os.path.isfile(path):
            continue
        data = _get(f"{WAGO}/db2/{t}/csv?build={build}")
        if not check_csv(data):
            raise SystemExit(f"recipe-catalog: unexpected response for {t}: {data[:80]!r}")
        with open(path, "wb") as f:
            f.write(data)
        log(f"fetched {t} ({data.count(b'\n')} rows)")
        time.sleep(0.5)


def read_tables(build):
    out = {}
    for t in TABLES:
        with open(os.path.join(csv_dir(build), t + ".csv"), encoding="utf-8", newline="") as f:
            out[t] = list(csv.DictReader(f))
    return out


# ---------------------------------------------------------------- recipes

def _int(v, default=0):
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return default


def profession_lines(skill_rows):
    """{skillLineID: professionSkillLine} for the profession lines and their child lines."""
    out = {}
    for r in skill_rows:
        sid, parent = _int(r.get("ID")), _int(r.get("ParentSkillLineID"))
        if sid in PROFESSIONS:
            out[sid] = sid
        elif parent in PROFESSIONS:
            out[sid] = parent
    return out


def build_recipes(t):
    """({recipeSpellID: recipe dict}, Counter of what was kept and dropped) from table rows."""
    lines = profession_lines(t["SkillLine"])
    effects = collections.defaultdict(list)
    for e in t["SpellEffect"]:
        if _int(e.get("DifficultyID")) == 0:
            effects[e["SpellID"]].append(e)
    reagents = {}
    for r in t["SpellReagents"]:
        regs = []
        for i in range(MAX_REAGENTS):
            item, count = _int(r.get(f"Reagent_{i}")), _int(r.get(f"ReagentCount_{i}"))
            if item > 0 and count > 0:
                regs.append((item, count))
        reagents[r["SpellID"]] = regs
    items = {_int(r["ID"]): r for r in t["ItemSparse"]}

    recipes, stats = {}, collections.Counter()
    for a in t["SkillLineAbility"]:
        profession = lines.get(_int(a.get("SkillLine")))
        if profession is None:
            continue
        spell = a["Spell"]
        effs = effects.get(spell, [])
        made = [e for e in effs if e.get("Effect") == EFFECT_CREATE_ITEM and _int(e.get("EffectItemType")) > 0]
        if not made:
            stats["enchant" if any(e.get("Effect") == EFFECT_ENCHANT_ITEM for e in effs) else "no item"] += 1
            continue
        output = _int(made[0]["EffectItemType"])
        regs = reagents.get(spell, [])
        if output not in items:
            stats["output not in ItemSparse"] += 1
            continue
        if not regs:
            stats["no reagents"] += 1
            continue
        if any(item not in items for item, _ in regs):
            stats["reagent not in ItemSparse"] += 1
            continue
        sid = _int(spell)
        if sid in recipes:
            stats["duplicate"] += 1
            continue
        flags = 0
        if sid >= NEW_SPELL_ID or output >= NEW_ITEM_ID:
            flags |= FLAG_NEW
        if _int(items[output].get("Bonding")) == 1:
            flags |= FLAG_BOP
        recipes[sid] = {
            "profession": profession,
            "minRank": _int(a.get("MinSkillLineRank")),
            "yellow": _int(a.get("TrivialSkillLineRankLow")),
            "grey": _int(a.get("TrivialSkillLineRankHigh")),
            "flags": flags,
            "output": output,
            "count": max(1, round(float(made[0].get("EffectBasePointsF") or 0))),
            "reagents": regs,
        }
        stats["kept"] += 1
    return recipes, stats


def reagent_ids(recipes):
    return {item for r in recipes.values() for item, _ in r["reagents"]}


# ---------------------------------------------------------------- vendor reagents

def vendor_list_path():
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "vendor_reagents.json")


def load_vendor_list(path=None):
    path = path or vendor_list_path()
    if not os.path.isfile(path):
        return {"items": {}}
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def save_vendor_list(data, path=None):
    path = path or vendor_list_path()
    data["items"] = dict(sorted(data["items"].items(), key=lambda kv: int(kv[0])))
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


def vendor_unit_price(item_row):
    """Copper per unit a vendor charges: BuyPrice buys VendorStackCount units (matches merchants [F-124])."""
    stack = max(1, _int(item_row.get("VendorStackCount"), 1))
    return _int(item_row.get("BuyPrice")) / stack


def merge_harvest(vendor_list, harvest, reagents, items, evidence):
    """Add harvested merchant items that are recipe reagents. harvest: {itemID: {...}} from
    BuffettForeverDB.vendor. Returns the itemIDs added."""
    added = []
    for key in harvest:
        item = _int(str(key).strip("[]"))
        if item not in reagents:
            continue
        entry = vendor_list["items"].setdefault(str(item), {})
        name = (items.get(item) or {}).get("Display_lang")
        if name:
            entry["name"] = name
        ev = entry.setdefault("evidence", [])
        if not any(e.startswith("harvest") for e in ev):
            ev.append(evidence)
            added.append(item)
    return added


def vendor_candidates(recipes, items, vendor_list, limit=30):
    """Reagents without vendor evidence that look vendor-sold, most used first (a review aid)."""
    uses = collections.Counter(item for r in recipes.values() for item, _ in r["reagents"])
    listed = {int(k) for k in vendor_list["items"]}
    out = []
    for item, n in uses.most_common():
        row = items.get(item)
        if item in listed or not row:
            continue
        name = row.get("Display_lang") or ""
        if _VENDORISH.search(name):
            out.append((item, name, vendor_unit_price(row), n))
    return out[:limit]


# ---------------------------------------------------------------- Lua output

def _num(x):
    return f"{x:.0f}" if float(x).is_integer() else f"{x:.4g}"


def emit_recipes_lua(recipes, build, generated, items=None):
    """Data/Recipes.lua: ns.Recipes[recipeSpellID] = { profession, minRank, yellowAt, greyAt, flags,
    outputItemID, outputCount, reagent1, count1, ... }, sorted by profession then recipe; and, when
    items (ItemSparse rows by ID) are given, ns.ItemSellPrice[itemID] = what a vendor pays per unit for
    every output and reagent (static per build, so no client item-cache round trip)."""
    lines = [
        "local addonName, ns = ...",
        "",
        "-- GENERATED by tools/wowf/recipe_catalog.py. Do not edit by hand.",
        f"-- Source: Forever build {build} game tables (wago.tools), generated {generated}.",
        "-- IDs and numbers only: item and spell names come from the client at run time.",
        "",
        f'ns.RecipesBuild = "{build}"',
        "",
        "-- [recipeSpellID] = { professionSkillLine, minRank, yellowAt, greyAt, flags, outputItemID, outputCount,",
        "--                     reagentItemID1, count1, reagentItemID2, count2, ... }",
        f"-- flags: {FLAG_NEW} = added after Classic (Season-of-Discovery or Forever-new IDs): unconfirmed until seen in",
        f"--        game; {FLAG_BOP} = the output binds on pickup",
        "local R = {}",
        "ns.Recipes = R",
    ]
    for sid, r in sorted(recipes.items(), key=lambda kv: (kv[1]["profession"], kv[0])):
        fields = [r["profession"], r["minRank"], r["yellow"], r["grey"], r["flags"], r["output"], r["count"]]
        for item, count in r["reagents"]:
            fields += [item, count]
        lines.append(f"R[{sid}] = {{{','.join(str(x) for x in fields)}}}")
    if items is not None:
        used = sorted({r["output"] for r in recipes.values()} | reagent_ids(recipes))
        lines += [
            "",
            "-- [itemID] = copper a vendor pays per unit (ItemSparse SellPrice) for every output and reagent; 0 left out.",
            "local S = {}",
            "ns.ItemSellPrice = S",
        ]
        for item in used:
            sell = _int((items.get(item) or {}).get("SellPrice"))
            if sell > 0:
                lines.append(f"S[{item}] = {sell}")
    return "\n".join(lines) + "\n"


def emit_vendor_lua(vendor_list, items, build, generated):
    """Data/Vendor.lua: ns.VendorSeed[itemID] = copper per unit, for the listed vendor reagents."""
    lines = [
        "local addonName, ns = ...",
        "",
        "-- GENERATED by tools/wowf/recipe_catalog.py from tools/wowf/data/vendor_reagents.json. Do not edit by hand.",
        f"-- Prices: ItemSparse BuyPrice / VendorStackCount, Forever build {build}, generated {generated}.",
        "-- [itemID] = copper per unit a vendor charges. A price harvested at a merchant wins over this.",
        "",
        f'ns.VendorSeedBuild = "{build}"',
        "local V = {}",
        "ns.VendorSeed = V",
    ]
    n = 0
    for key in sorted(vendor_list["items"], key=int):
        row = items.get(int(key))
        if not row:
            continue
        price = vendor_unit_price(row)
        if price > 0:
            lines.append(f"V[{int(key)}] = {_num(price)}")
            n += 1
    return "\n".join(lines) + "\n", n


# ---------------------------------------------------------------- SavedVariables harvest

def harvested_vendors(cfg):
    """[(client, build, BuffettForeverDB.vendor)] from every client's account SavedVariables."""
    import savedvars
    out = []
    for key, client in config.discover_clients(cfg).items():
        for scope, _, path in savedvars.find_sv_files(client["dir"], "BuffettForever"):
            if scope != "account":
                continue
            db = savedvars.load_sv(path).get("BuffettForeverDB") or {}
            vendor = db.get("vendor")
            if isinstance(vendor, dict) and vendor:
                build = ((db.get("diag") or {}).get("build")) or client.get("build") or "?"
                out.append((key, build, vendor))
    return out


# ---------------------------------------------------------------- CLI

def _summary(recipes, stats):
    by_prof = collections.Counter(PROFESSIONS[r["profession"]] for r in recipes.values())
    new = sum(1 for r in recipes.values() if r["flags"] & FLAG_NEW)
    lines = [f"{len(recipes)} recipes ({new} new since Classic, unconfirmed); dropped: " +
             ", ".join(f"{k} {v}" for k, v in sorted(stats.items()) if k != "kept")]
    lines += [f"  {name:15} {n}" for name, n in by_prof.most_common()]
    return "\n".join(lines)


def main(argv):
    p = argparse.ArgumentParser(prog="wowf recipe-catalog")
    p.add_argument("action", choices=["fetch", "build", "show", "vendor-merge"])
    p.add_argument("--build", default=DEFAULT_BUILD)
    p.add_argument("--out", help="output folder (default: BuffettForever/Data)")
    p.add_argument("--item", type=int, help="show: the recipes that use or make this item")
    a = p.parse_args(argv)
    fetch_tables(a.build)
    if a.action == "fetch":
        return 0
    t = read_tables(a.build)
    recipes, stats = build_recipes(t)
    items = {_int(r["ID"]): r for r in t["ItemSparse"]}
    vendor_list = load_vendor_list()

    if a.action == "show":
        if a.item:
            spells = {_int(r["ID"]): r["Name_lang"] for r in t["SpellName"]}
            name = lambda i: (items.get(i) or {}).get("Display_lang", "?")  # noqa: E731
            for sid, r in sorted(recipes.items()):
                regs = r["reagents"]
                if r["output"] == a.item or any(i == a.item for i, _ in regs):
                    need = ", ".join(f"{c} x {name(i)}" for i, c in regs)
                    print(f"{sid} {spells.get(sid, '?')} [{PROFESSIONS[r['profession']]} {r['yellow']}/{r['grey']}"
                          f" flags {r['flags']}] -> {r['count']} x {name(r['output'])}: {need}")
            return 0
        print(_summary(recipes, stats))
        return 0

    if a.action == "vendor-merge":
        found = harvested_vendors(config.load())
        if not found:
            print("no BuffettForever merchant harvest found in any client's SavedVariables")
            return 1
        reagents = reagent_ids(recipes)
        for client, build, harvest in found:
            added = merge_harvest(vendor_list, harvest, reagents, items,
                                  f"harvest {client} {build} {time.strftime('%Y-%m-%d')}")
            print(f"{client}: {len(harvest)} harvested items, {len(added)} reagents added")
        vendor_list["note"] = ("Reagents a vendor sells, with the evidence for each. 'harvest' = BuffettForever's "
                               "merchant harvest saw it on sale. Prices come from ItemSparse at build time.")
        save_vendor_list(vendor_list)
        print(f"wrote {vendor_list_path()}: {len(vendor_list['items'])} vendor reagents")
        cands = vendor_candidates(recipes, items, vendor_list)
        if cands:
            print("unconfirmed reagents that look vendor-sold (check at a trade-goods vendor):")
            for item, name, price, n in cands:
                print(f"  {item} {name}: {_num(price)}c each, used by {n} recipes")
        return 0

    cfg = config.load()
    out = a.out or os.path.join(cfg["_root"], "BuffettForever", "Data")
    os.makedirs(out, exist_ok=True)
    generated = time.strftime("%Y-%m-%d")
    text = emit_recipes_lua(recipes, a.build, generated, items)
    with open(os.path.join(out, "Recipes.lua"), "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    vtext, nv = emit_vendor_lua(vendor_list, items, a.build, generated)
    with open(os.path.join(out, "Vendor.lua"), "w", encoding="utf-8", newline="\n") as f:
        f.write(vtext)
    print(_summary(recipes, stats))
    print(f"wrote {out}: Recipes.lua {len(text.encode('utf-8')) // 1024} KB, Vendor.lua {nv} vendor prices")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
