import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import config  # noqa: E402
import index as idx  # noqa: E402
import lint  # noqa: E402
import probe_report  # noqa: E402

FIX = os.path.join(HERE, "fixtures")
CFG = config.load(config.repo_root(HERE))
I = idx.Index(CFG["_root"])

EXPECTED_BAD = {
    "TOC001", "TOC002", "TOC003", "TOC004", "TOC005", "TOC006", "TOC007",
    "LUA001", "LUA002", "LUA003", "LUA004",
    "API001", "API002", "API003", "API005", "API006", "API007",
    "PAT001", "PAT002", "PAT003", "PAT004", "PAT005",
    "SEC001", "SEC002",
}


@unittest.skipUnless(I.loaded, "API index not built")
class LintGolden(unittest.TestCase):
    def ids(self, name, luacheck=False):
        findings, _, _ = lint.lint_dir(os.path.join(FIX, name), CFG, I, use_luacheck=luacheck)
        return findings

    def test_bad_addon_hits_every_tier1_rule(self):
        got = {f.id for f in self.ids("BadAddon")}
        self.assertEqual(EXPECTED_BAD - got, set(), "rules that failed to fire")

    def test_good_addon_is_clean(self):
        bad = [f.text(CFG["_root"]) for f in self.ids("GoodAddon") if f.sev in ("E", "W")]
        self.assertEqual(bad, [])

    def test_good_addon_clean_with_luacheck(self):
        if not os.path.isfile(os.path.join(CFG["_root"], "tools", "luacheck.exe")):
            self.skipTest("luacheck.exe not installed")
        bad = [f.text(CFG["_root"]) for f in self.ids("GoodAddon", luacheck=True) if f.sev in ("E", "W")]
        self.assertEqual(bad, [])

    def test_false_positive_guards(self):
        # GoodAddon contains: ~=, os.time(), goto inside strings/comments, Interface\AddOns sound path,
        # SV access inside a function, UnitHealth fed to a StatusBar.
        got = {f.id for f in self.ids("GoodAddon")}
        for rid in ("LUA001", "LUA003", "API001", "API006", "PAT001", "SEC001"):
            self.assertNotIn(rid, got)

    def test_wowfprobe_is_clean(self):
        probe = os.path.join(CFG["_root"], ".claude", "skills", "wowf-debug", "assets", "WowfProbe")
        findings, _, _ = lint.lint_dir(probe, CFG, I, use_luacheck=False)
        self.assertEqual([f.text(CFG["_root"]) for f in findings if f.sev in ("E", "W")], [])

    def test_secret_guard_through_ns_issecret(self):
        # The scaffold's ns.IsSecret(v) counts as a guard, like a literal issecretvalue(v).
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            a = os.path.join(d, "Guard")
            os.makedirs(a)
            with open(os.path.join(a, "Guard.toc"), "w") as f:
                f.write("## Interface: 16001\n\nCore.lua\n")
            with open(os.path.join(a, "Core.lua"), "w") as f:
                f.write("local addonName, ns = ...\n"
                        "function ns.Key()\n"
                        "    local first, surname = UnitFullName(\"player\")\n"
                        "    if not first or ns.IsSecret(first) or ns.IsSecret(surname) then return nil end\n"
                        "    if surname and surname ~= \"\" then return first .. \" \" .. surname end\n"
                        "    return first\n"
                        "end\n")
            findings, _, _ = lint.lint_dir(a, CFG, I, use_luacheck=False)
            self.assertNotIn("SEC001", {x.id for x in findings})

    def test_suppression(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            a = os.path.join(d, "Sup")
            os.makedirs(a)
            with open(os.path.join(a, "Sup.toc"), "w") as f:
                f.write("## Interface: 16001\n\nCore.lua\n")
            with open(os.path.join(a, "Core.lua"), "w") as f:
                f.write("local addonName, ns = ...\n-- wowf-ignore: SEC002 testing\nChatFrame_OpenChat('x')\n")
            findings, suppressed, _ = lint.lint_dir(a, CFG, I, use_luacheck=False)
            self.assertNotIn("SEC002", {x.id for x in findings})
            self.assertEqual(suppressed, 1)


@unittest.skipUnless(I.loaded, "API index not built")
class ScaffoldTests(unittest.TestCase):
    def _lint_scaffold(self, files):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            dest = os.path.join(d, "ScaffoldProbe")
            for rel, content in files.items():
                p = os.path.join(dest, rel)
                os.makedirs(os.path.dirname(p), exist_ok=True)
                with open(p, "w", encoding="utf-8", newline="\n") as f:
                    f.write(content)
            findings, _, _ = lint.lint_dir(dest, CFG, I, use_luacheck=False)
            return [f.text(CFG["_root"]) for f in findings if f.sev in ("E", "W")]

    def test_scaffold_lints_clean(self):
        import scaffold
        _, files = scaffold.build(CFG["_root"], "ScaffoldProbe", 'Scaffold "Probe"', "notes", "Justin", "Media", None,
                                  scaffold.ALL_FEATURES)
        self.assertEqual(self._lint_scaffold(files), [])

    def test_scaffold_window_signature_icon_lints_clean(self):
        import json
        import scaffold
        _, files = scaffold.build(CFG["_root"], "ScaffoldProbe", "Scaffold Probe", "notes", "Typheous", "Miscellaneous",
                                  "sp,scaffoldprobe", scaffold.ALL_FEATURES, signature="Typheous", icon=True)
        self.assertEqual(self._lint_scaffold(files), [])
        toc = files["ScaffoldProbe.toc"]
        self.assertIn("## Title: Scaffold Probe |cff9d9d9dby Typheous|r", toc)
        self.assertIn("## IconTexture: Interface\\AddOns\\ScaffoldProbe\\Media\\Icon.tga", toc)
        self.assertLess(toc.index("UI\\Widgets.lua"), toc.index("UI\\MainFrame.lua"))
        self.assertIn('signature:SetText(ns.L["by Typheous"])', files["UI\\MainFrame.lua"])
        self.assertIn('SLASH_SCAFFOLDPROBE2 = "/scaffoldprobe"', files["Slash.lua"])
        self.assertIn("ns.Main.Toggle()", files["Compartment.lua"])
        settings = json.loads(files[".claude\\settings.json"])
        self.assertEqual(settings["permissions"]["additionalDirectories"], [".."])
        self.assertIn("# ScaffoldProbe", files["CLAUDE.md"])

    def test_scaffold_minimal_lints_clean(self):
        import scaffold
        _, files = scaffold.build(CFG["_root"], "ScaffoldProbe", "Scaffold Probe", "notes", "Typheous", "Miscellaneous",
                                  None, ["slash", "compartment"])
        self.assertEqual(self._lint_scaffold(files), [])
        self.assertNotIn("CLAUDE.md", files)
        self.assertIn("ns.db.enabled = not ns.db.enabled", files["Compartment.lua"])


class ProbeReportTests(unittest.TestCase):
    def test_surface_names(self):
        run = {"meta": {"globals": {"PlayMusic": "function", "GetSpellInfo": "nil"}},
               "quick": {"namespaces": {"C_Sound": "IsPlaying\nPlaySound"}, "libs": {"bit": "band\nbor"}},
               "full": {"function": "CreateFrame\nPlaySoundFile", "enum": {"GameRule": "UserAddonsDisabled"}}}
        names = probe_report.surface_names(run)
        for n in ("C_Sound", "C_Sound.PlaySound", "bit.band", "CreateFrame", "PlaySoundFile", "PlayMusic", "Enum.GameRule.UserAddonsDisabled"):
            self.assertIn(n, names)
        self.assertNotIn("GetSpellInfo", names)


if __name__ == "__main__":
    unittest.main()
