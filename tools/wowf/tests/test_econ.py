import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import econ  # noqa: E402
import lua_lexer  # noqa: E402

LINEN, BOLT = econ.LINEN, econ.BOLT


def scenario(name):
    for n, recipe, crafts, ctx in econ.scenarios():
        if n == name:
            return econ.evaluate(recipe, crafts, ctx)
    raise KeyError(name)


class ReferenceVectors(unittest.TestCase):
    """The test vectors printed in the wowf-economics references."""

    def test_buy(self):
        ladder = [950, 20, 1000, 40, 1100, 100]
        self.assertEqual(econ.cost_to_buy(ladder, 8), (7600, True, 8))
        self.assertEqual(econ.cost_to_buy(ladder, 70), (70000, True, 70))
        self.assertEqual(econ.cost_to_buy(ladder, 200), (169000, False, 160))

    def test_fair(self):
        self.assertAlmostEqual(econ.fair_value({100: 100, 99: 120, 97: 80}, 100), 102.561, places=3)
        self.assertIsNone(econ.fair_value({80: 100}, 100))

    def test_net_mob_roi(self):
        self.assertAlmostEqual(econ.ah_net(2900, 0.05, 60, 0.5), 2695)
        ctx = econ._ctx(vendorBuy={2840: 60, 3576: 90}, ladder={2841: [80, 10]},
                        recipeFor={2841: {"yield": 2, "reagents": [2840, 1, 3576, 1]}})
        self.assertEqual(econ.acquire(2841, 4, ctx), (300, "craft"))
        self.assertIsNone(econ.roi(500, 0))

    def test_craft_and_vendor(self):
        ctx = econ._ctx({"minGrade": "D"}, vendorSell={LINEN: 13, BOLT: 40}, sellPrice={LINEN: 950, BOLT: 2900},
                        ladder={LINEN: [950, 20, 1000, 40, 1100, 100]}, owned={LINEN: 6})
        bolt = econ._recipe(2963, BOLT, 1, [(LINEN, 2)])
        r = econ.evaluate(bolt, 10, ctx)
        self.assertAlmostEqual(r["cogs"], 18715)
        self.assertAlmostEqual(r["ahExit"], 27550)
        self.assertEqual(r["vendorExit"], 400)
        self.assertAlmostEqual(r["profit"], 8835)
        self.assertAlmostEqual(r["roi"], 0.47208, places=5)
        self.assertAlmostEqual(r["valueAdded"], 9500)
        ctx["deposit"] = {BOLT: 60}
        r = econ.evaluate(bolt, 10, ctx)
        self.assertAlmostEqual(r["ahExit"], 26950)
        self.assertAlmostEqual(r["roi"], 0.44002, places=5)
        bronze = econ._recipe(2659, 2841, 2, [(2840, 1), (3576, 1)])
        r = econ.evaluate(bronze, 1, econ._ctx(vendorSell={2840: 10, 3576: 35, 2841: 50}, owned={2840: 1, 3576: 1}))
        self.assertEqual((r["cogs"], r["vendorExit"], r["profit"], r["bestSource"]), (45, 100, 55, "vendor"))

    def test_grades(self):
        self.assertEqual(econ.grade(3600, 5, 6, 0.10, 200, 50), "A")
        self.assertEqual(econ.grade(30 * 3600, 5, 6, 0.10, 200, 50), "B")
        self.assertEqual(econ.grade(3600, 1, 2, None, 80, 50), "C")
        self.assertEqual(econ.grade(3600, 5, 6, 0.10, 40, 50), "D")
        self.assertEqual(econ.grade(None, 5, 6, 0.1, 100, None), "D")


class Branches(unittest.TestCase):
    """Each scenario lands on the branch its name promises (the Lua is then held to these results)."""

    def test_min_profit_and_recommendation(self):
        self.assertEqual(scenario("BOLT-UNDER-MIN")["reasons"], ["underMinProfit"])
        self.assertTrue(scenario("BOLT-RECOMMENDED")["recommended"])
        self.assertTrue(scenario("BOLT-DEPOSIT")["recommended"])

    def test_replacement_policy(self):
        self.assertAlmostEqual(scenario("BOLT-REPLACEMENT")["cogs"], 19000)

    def test_cant_fill_and_no_price(self):
        r = scenario("BOLT-CANT-FILL")
        self.assertEqual(r["warnings"], [["cantFill", LINEN, 60, 134]])
        self.assertEqual(r["reasons"], ["noReagentPrice"])
        self.assertIsNone(r["profit"])
        r = scenario("BOLT-NO-REAGENT-PRICE")
        self.assertEqual(r["warnings"], [["noPrice", LINEN]])
        self.assertEqual(r["reasons"], ["noReagentPrice"])

    def test_grades_on_recipes(self):
        r = scenario("BOLT-THIN-DATA")
        self.assertEqual((r["grade"], r["reasons"]), ("D", ["thinData"]))
        r = scenario("BOLT-STALE-C")
        self.assertEqual((r["grade"], r["recommended"]), ("C", True))

    def test_exits(self):
        r = scenario("BOLT-UNDER-MARGIN")
        self.assertEqual((r["bestSource"], r["underMargin"]), ("vendor", True))
        self.assertIn("loss", r["reasons"])
        r = scenario("BOLT-BOP")
        self.assertIsNone(r["ahExit"])
        self.assertEqual(r["bestSource"], "vendor")
        self.assertEqual(scenario("BOLT-LOSS")["reasons"], ["loss"])
        self.assertEqual(scenario("BOLT-NO-EXIT")["reasons"], ["noExit"])
        self.assertEqual(scenario("BOLT-ROI-UNDER-MARGIN")["reasons"], ["roiUnderMargin"])

    def test_free_policy(self):
        r = scenario("BOLT-FREE-SELL-RAW")
        self.assertEqual((r["cogs"], r["roi"], r["reasons"]), (0, None, ["sellRaw"]))
        r = scenario("BOLT-FREE-GOOD")
        self.assertTrue(r["recommended"])
        self.assertIsNone(r["roi"])

    def test_make_or_buy(self):
        r = scenario("BRACERS-MAKE-OR-BUY")
        self.assertEqual((r["lines"][0]["source"], r["lines"][0]["buyCost"]), ("craft", 300))
        self.assertTrue(r["recommended"])
        r = scenario("BRONZE-PARTIAL")
        self.assertEqual([line["source"] for line in r["lines"]], ["ah", "vendor"])
        self.assertAlmostEqual(r["cogs"], 1450)
        self.assertEqual(r["grade"], "B")

    def test_cycle_and_depth(self):
        r = scenario("CYCLE-GUARD")
        self.assertEqual((r["lines"][0]["source"], r["lines"][0]["buyCost"]), ("vendor", 100))
        r = scenario("DEPTH-LIMIT")
        self.assertEqual((r["lines"][0]["source"], r["lines"][0]["buyCost"]), ("vendor", 900))


class Outputs(unittest.TestCase):
    def test_vectors_lua(self):
        text = econ.emit_vectors_lua(econ.vectors(), "2026-10-16")
        lua_lexer.tokenize(text.encode("utf-8"))
        self.assertEqual(text.count("{"), text.count("}"))
        for name, _, _, _ in econ.scenarios():
            self.assertIn(f'name = "{name}"', text)
        self.assertIn("ns.EvaluatorVectors = {", text)

    def _snapshot(self):
        """A /bf eval snapshot in the shape the Lua writes, built from two scenarios."""
        results, ctx = [], None
        for name in ("BOLT-RECOMMENDED", "BOLT-UNDER-MIN"):
            for n, recipe, crafts, c in econ.scenarios():
                if n == name:
                    ctx = c
                    r = econ.evaluate(recipe, crafts, c)
                    flat = [x for pair in recipe["reagents"] for x in pair]
                    results.append(dict(
                        recipeID=recipe["recipeID"] + len(results), output=recipe["output"], count=recipe["count"],
                        bop=recipe["bop"], reagents=flat, crafts=crafts, cogs=r["cogs"], vendorExit=r["vendorExit"],
                        ahExit=r["ahExit"], best=r["best"], bestSource=r["bestSource"], profit=r["profit"], roi=r["roi"],
                        valueAdded=r["valueAdded"], grade=r["grade"], recommended=r["recommended"],
                        reasons=r["reasons"], sources=[line["source"] or "-" for line in r["lines"]]))
        # both scenarios share their tables; the snapshot holds one context (with the stricter settings)
        lua_ctx = {k: v for k, v in ctx.items() if k != "settings"}
        return {"t": 0, "settings": ctx["settings"], "ctx": lua_ctx, "results": results, "tray": []}

    def test_check_snapshot_agrees_then_catches_a_difference(self):
        snap = self._snapshot()
        snap["settings"] = dict(snap["settings"], minProfit=1000)
        # with minProfit 1000 both rows are "under the minimum"; make the Lua side say the same
        for res in snap["results"]:
            res["recommended"], res["reasons"] = False, ["underMinProfit"]
        snap["results"].sort(key=lambda res: res["recipeID"])
        checked, mismatches, order_ok = econ.check_snapshot(snap)
        self.assertEqual((checked, mismatches), (2, []))
        self.assertTrue(order_ok)
        snap["results"][0]["cogs"] += 5
        _, mismatches, _ = econ.check_snapshot(snap)
        self.assertEqual(len(mismatches), 1)
        self.assertIn("cogs", mismatches[0][1][0])

    def test_vendor_cap_invariant(self):
        snap = self._snapshot()
        self.assertEqual(econ.cap_violations(snap), [])
        snap["ctx"]["vendorBuy"] = {2320: 10}
        snap["ctx"]["sellPrice"] = {**snap["ctx"]["sellPrice"], 2320: 19}   # Coarse Thread on 70425
        self.assertEqual(econ.cap_violations(snap), [(2320, 19, 10)])

    def test_report_and_money(self):
        self.assertEqual(econ._money(18715), "1g 87s 15c")
        self.assertEqual(econ._money(-475), "-4s 75c")
        self.assertEqual(econ._money(7), "7c")
        text = econ.report(self._snapshot(), {BOLT: "Bolt of Linen Cloth"}, {}, top=5)
        self.assertIn("2 recipes, ", text)
        self.assertIn("Bolt of Linen Cloth x10: cost 1g 87s 15c", text)


if __name__ == "__main__":
    unittest.main()
