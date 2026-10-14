import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import deploy  # noqa: E402
import savedvars  # noqa: E402


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


class DeployTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="wowf test ")  # space in path on purpose
        base = self.tmp.name
        self.root = os.path.join(base, "repo with space")
        self.src = os.path.join(self.root, "MyAddon")
        write(os.path.join(self.src, "MyAddon.toc"), "## Interface: 16001\n\nCore.lua\n")
        write(os.path.join(self.src, "Core.lua"), "local addonName, ns = ...\n")
        self.client = {"addons": os.path.join(base, "client", "Interface", "AddOns")}
        os.makedirs(self.client["addons"])
        self.link = os.path.join(self.client["addons"], "MyAddon")

    def tearDown(self):
        if os.path.isjunction(self.link):
            os.rmdir(self.link)
        self.tmp.cleanup()

    def test_create_status_remove_keeps_source(self):
        folder = deploy.validate_source(self.root, self.src)
        msg = deploy.deploy_one(self.root, self.src, folder, self.client, "junction", False, False)
        self.assertIn("linked", msg)
        self.assertTrue(os.path.isjunction(self.link))
        self.assertTrue(deploy.describe(self.link).startswith("junction"))
        self.assertIn("already linked", deploy.deploy_one(self.root, self.src, folder, self.client, "junction", False, False))
        deploy.remove_link(self.link, self.root)
        self.assertFalse(os.path.lexists(self.link))
        self.assertTrue(os.path.isfile(os.path.join(self.src, "Core.lua")), "source must survive removal")

    def test_refuses_real_folder(self):
        os.makedirs(self.link)
        write(os.path.join(self.link, "Installed.lua"), "-- curseforge copy\n")
        with self.assertRaises(SystemExit):
            deploy.deploy_one(self.root, self.src, "MyAddon", self.client, "junction", False, False)
        with self.assertRaises(SystemExit):
            deploy.remove_link(self.link, self.root)
        self.assertTrue(os.path.isfile(os.path.join(self.link, "Installed.lua")))

    def test_dangling_detection(self):
        other = os.path.join(self.root, "Gone")
        os.makedirs(other)
        deploy.make_junction(self.link, other)
        os.rmdir(other)
        self.assertTrue(deploy.describe(self.link).startswith("DANGLING"))

    def test_toc_name_must_match(self):
        bad = os.path.join(self.root, "Wrong")
        write(os.path.join(bad, "Other.toc"), "## Interface: 16001\n")
        with self.assertRaises(SystemExit):
            deploy.validate_source(self.root, bad)


class SavedVarsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.client = self.tmp.name
        acct = os.path.join(self.client, "WTF", "Account", "123456#1")
        write(os.path.join(acct, "SavedVariables", "MyAddon.lua"), 'MyAddonDB = {\n\t["count"] = 2,\n}\n')
        write(os.path.join(acct, "SavedVariables", "MyAddon.lua.bak"), 'MyAddonDB = {\n\t["count"] = 1,\n}\n')
        write(os.path.join(acct, "70", "Hero-Realm", "SavedVariables", "MyAddon.lua"), "MyAddonCharDB = {\n\t[\"x\"] = true,\n}\n")
        write(os.path.join(acct, "70", "Hero-Realm", "AddOns.txt"), "MyAddon: enabled\nOther: disabled\n")

    def tearDown(self):
        self.tmp.cleanup()

    def test_find_and_parse(self):
        files = savedvars.find_sv_files(self.client, "myaddon")
        scopes = sorted((s, l) for s, l, _ in files)
        self.assertEqual(scopes, [("account", "123456#1"), ("character", "123456#1/70/Hero-Realm")])
        acct = [p for s, _, p in files if s == "account"][0]
        self.assertEqual(savedvars.load_sv(acct)["MyAddonDB"]["count"], 2)

    def test_diff_bak(self):
        acct = os.path.join(self.client, "WTF", "Account", "123456#1", "SavedVariables", "MyAddon.lua")
        lines = savedvars.diff(savedvars.load_sv(acct + ".bak"), savedvars.load_sv(acct))
        self.assertEqual(lines, ["~ MyAddonDB.count: 1 -> 2"])

    def test_addons_txt(self):
        self.assertEqual(len(savedvars.find_addons_txt(self.client)), 1)

    def test_select_path(self):
        self.assertEqual(savedvars.select_path({"a": [{"b": 5}]}, "a.1.b"), 5)


if __name__ == "__main__":
    unittest.main()
