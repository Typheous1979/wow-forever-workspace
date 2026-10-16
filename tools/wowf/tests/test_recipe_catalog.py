import os
import re
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import lua_lexer  # noqa: E402
import recipe_catalog as rc  # noqa: E402


def effect(spell, effect_id, item="0", count="1", difficulty="0"):
    return {"SpellID": str(spell), "Effect": str(effect_id), "EffectItemType": str(item),
            "EffectBasePointsF": str(count), "DifficultyID": difficulty}


def reagents(spell, *pairs):
    row = {"SpellID": str(spell)}
    for i in range(8):
        item, count = pairs[i] if i < len(pairs) else (0, 0)
        row[f"Reagent_{i}"], row[f"ReagentCount_{i}"] = str(item), str(count)
    return row


def ability(spell, line, low="25", high="50", rank="1"):
    return {"SkillLine": str(line), "Spell": str(spell), "MinSkillLineRank": rank,
            "TrivialSkillLineRankLow": low, "TrivialSkillLineRankHigh": high}


def item(iid, name="x", bonding="0", buy="0", stack="1"):
    return {"ID": str(iid), "Display_lang": name, "Bonding": bonding, "BuyPrice": str(buy), "VendorStackCount": str(stack)}


def tables():
    """Shapes taken from the 70450 tables (wago.tools)."""
    return {
        "SkillLine": [
            {"ID": "197", "ParentSkillLineID": "0"},      # Tailoring
            {"ID": "171", "ParentSkillLineID": "0"},      # Alchemy
            {"ID": "186", "ParentSkillLineID": "0"},      # Mining
            {"ID": "2948", "ParentSkillLineID": "197"},   # Forever's Tailoring child line
            {"ID": "40", "ParentSkillLineID": "0"},       # Poisons: a class skill, not a profession
        ],
        "SkillLineAbility": [
            ability(2963, 197),                     # Bolt of Linen Cloth: 2 Linen Cloth -> 1 bolt
            ability(11479, 171, "275", "295"),      # Transmute: Iron to Gold, count 0 -> 1
            ability(2659, 186, "65", "90"),         # Smelt Bronze: 2 bars
            ability(7418, 197),                     # an enchant-only spell (Effect 53): left out
            ability(5000, 197),                     # output encrypted (not in ItemSparse)
            ability(5001, 197),                     # a reagent encrypted
            ability(450000, 2948),                  # new (post-Classic) spell on the child line, BoP output
            ability(8681, 40),                      # Instant Poison on Poisons: not a profession
        ],
        "SpellEffect": [
            effect(2963, 24, 2996, "1"),
            effect(2963, 24, 9999, "1", difficulty="1"),   # another difficulty: ignored
            effect(11479, 24, 3577, "0"),
            effect(2659, 24, 2841, "2"),
            effect(7418, 53),
            effect(5000, 24, 777777, "1"),
            effect(5001, 24, 2996, "1"),
            effect(450000, 24, 215000, "1"),
            effect(8681, 24, 6947, "1"),
        ],
        "SpellReagents": [
            reagents(2963, (2589, 2)),
            reagents(11479, (3575, 1)),
            reagents(2659, (2840, 1), (3576, 1)),
            reagents(5000, (2589, 1)),
            reagents(5001, (888888, 1)),
            reagents(450000, (2996, 3), (2321, 1)),
            reagents(8681, (2928, 1)),
        ],
        "SpellName": [],
        "ItemSparse": [
            item(2589, "Linen Cloth"), item(2996, "Bolt of Linen Cloth"), item(3577, "Gold Bar"),
            item(3575, "Iron Bar"), item(2840, "Copper Bar"), item(3576, "Tin Bar"), item(2841, "Bronze Bar"),
            item(2321, "Fine Thread", buy=100), item(2320, "Coarse Thread", buy=10), item(2678, "Mild Spices", buy=10, stack=5),
            item(215000, "New Robe", bonding="1"), item(6947, "Instant Poison"), item(2928, "Dust of Decay"),
        ],
    }


class Recipes(unittest.TestCase):
    def setUp(self):
        self.recipes, self.stats = rc.build_recipes(tables())

    def test_profession_lines_map_child_lines(self):
        lines = rc.profession_lines(tables()["SkillLine"])
        self.assertEqual(lines[197], 197)
        self.assertEqual(lines[2948], 197)
        self.assertNotIn(40, lines)

    def test_keeps_complete_recipes(self):
        self.assertEqual(set(self.recipes), {2963, 11479, 2659, 450000})
        bolt = self.recipes[2963]
        self.assertEqual((bolt["profession"], bolt["yellow"], bolt["grey"], bolt["output"], bolt["count"]),
                         (197, 25, 50, 2996, 1))
        self.assertEqual(bolt["reagents"], [(2589, 2)])
        self.assertEqual(self.recipes[2659]["count"], 2)
        self.assertEqual(self.recipes[2659]["reagents"], [(2840, 1), (3576, 1)])

    def test_zero_count_means_one(self):
        self.assertEqual(self.recipes[11479]["count"], 1)

    def test_drops_and_counts_the_rest(self):
        self.assertEqual(self.stats["enchant"], 1)
        self.assertEqual(self.stats["output not in ItemSparse"], 1)
        self.assertEqual(self.stats["reagent not in ItemSparse"], 1)
        self.assertEqual(self.stats["kept"], 4)

    def test_flags(self):
        new = self.recipes[450000]
        self.assertEqual(new["profession"], 197)               # child line -> Tailoring
        self.assertEqual(new["flags"], rc.FLAG_NEW | rc.FLAG_BOP)
        self.assertEqual(self.recipes[2963]["flags"], 0)

    def test_recipes_lua(self):
        text = rc.emit_recipes_lua(self.recipes, "1.60.1.70450", "2026-10-16")
        self.assertTrue(text.startswith("local addonName, ns = ...\n"))
        self.assertIn('ns.RecipesBuild = "1.60.1.70450"', text)
        self.assertIn("R[2963] = {197,1,25,50,0,2996,1,2589,2}", text)
        self.assertIn("R[2659] = {186,1,65,90,0,2841,2,2840,1,3576,1}", text)
        # sorted by profession skill line, then recipe ID: Alchemy 171, Mining 186, Tailoring 197
        self.assertEqual(re.findall(r"^R\[(\d+)\]", text, re.M), ["11479", "2659", "2963", "450000"])
        lua_lexer.tokenize(text.encode("utf-8"))               # raises LuaSyntaxError on bad Lua
        self.assertEqual(text.count("{"), text.count("}"))


class Vendors(unittest.TestCase):
    def test_check_csv_accepts_id_anywhere(self):
        self.assertTrue(rc.check_csv(b"DisplayName_lang,ID,CategoryID\nTailoring,197,11\n"))
        self.assertTrue(rc.check_csv(b"ID,SpellID\n1,2\n"))
        self.assertFalse(rc.check_csv(b"<!DOCTYPE html><html>"))

    def test_unit_price_per_vendor_stack(self):
        self.assertEqual(rc.vendor_unit_price(item(2678, buy=10, stack=5)), 2)
        self.assertEqual(rc.vendor_unit_price(item(2320, buy=10)), 10)
        self.assertEqual(rc.vendor_unit_price(item(1, buy=5, stack=0)), 5)

    def test_merge_harvest_keeps_reagents_only(self):
        recipes, _ = rc.build_recipes(tables())
        items = {int(r["ID"]): r for r in tables()["ItemSparse"]}
        listing = {"items": {}}
        harvest = {2321: {"p": 100}, 7005: {"p": 10}}          # Fine Thread (a reagent), Skinning Knife (not)
        added = rc.merge_harvest(listing, harvest, rc.reagent_ids(recipes), items, "harvest beta 70425 2026-10-16")
        self.assertEqual(added, [2321])
        self.assertEqual(listing["items"]["2321"]["name"], "Fine Thread")
        self.assertEqual(rc.merge_harvest(listing, harvest, rc.reagent_ids(recipes), items, "again"), [])

    def test_vendor_lua(self):
        items = {int(r["ID"]): r for r in tables()["ItemSparse"]}
        listing = {"items": {"2678": {"name": "Mild Spices"}, "2321": {}, "123456": {}}}
        text, n = rc.emit_vendor_lua(listing, items, "1.60.1.70450", "2026-10-16")
        self.assertEqual(n, 2)                                  # 123456 isn't in ItemSparse
        self.assertIn("V[2321] = 100", text)
        self.assertIn("V[2678] = 2", text)
        lua_lexer.tokenize(text.encode("utf-8"))

    def test_candidates_skip_listed_items(self):
        t = tables()
        recipes, _ = rc.build_recipes(t)
        items = {int(r["ID"]): r for r in t["ItemSparse"]}
        cands = rc.vendor_candidates(recipes, items, {"items": {}})
        self.assertIn(2321, [c[0] for c in cands])             # "Fine Thread" looks vendor-sold
        self.assertNotIn(2589, [c[0] for c in cands])          # Linen Cloth doesn't
        cands = rc.vendor_candidates(recipes, items, {"items": {"2321": {}}})
        self.assertNotIn(2321, [c[0] for c in cands])


if __name__ == "__main__":
    unittest.main()
