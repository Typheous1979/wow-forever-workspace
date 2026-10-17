import os
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import package  # noqa: E402


def write(path, text=""):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


class PackageTests(unittest.TestCase):
    def test_zip_has_one_root_folder_and_skips_personal_files(self):
        with tempfile.TemporaryDirectory() as d:
            addon = os.path.join(d, "MyAddon")
            write(os.path.join(addon, "MyAddon.toc"), "## Interface: 16001\n## Version: 1.2.3\n\nCore.lua\n")
            write(os.path.join(addon, "Core.lua"), "local addonName, ns = ...\n")
            write(os.path.join(addon, "Media", "Icon.tga"), "x")
            write(os.path.join(addon, "Screenshots", "Error01.png"), "x")
            write(os.path.join(addon, "desktop.ini"), "x")
            zip_path, version, _ = package.build_zip(addon, os.path.join(d, "dist"))
            self.assertEqual(version, "1.2.3")
            self.assertTrue(zip_path.endswith("MyAddon-1.2.3.zip"))
            names = sorted(zipfile.ZipFile(zip_path).namelist())
            self.assertEqual(names, ["MyAddon/Core.lua", "MyAddon/Media/Icon.tga", "MyAddon/MyAddon.toc"])

    def test_skips_agent_notes_and_dot_folders(self):
        with tempfile.TemporaryDirectory() as d:
            addon = os.path.join(d, "MyAddon")
            write(os.path.join(addon, "MyAddon.toc"), "## Interface: 16001\n## Version: 0.1.0\n\nCore.lua\n")
            write(os.path.join(addon, "Core.lua"), "local addonName, ns = ...\n")
            write(os.path.join(addon, "CLAUDE.md"), "# notes for the agent\n")
            write(os.path.join(addon, "AGENTS.md"), "x")
            write(os.path.join(addon, ".claude", "settings.json"), "{}")
            write(os.path.join(addon, "README.md"), "# MyAddon\n")
            zip_path, _, _ = package.build_zip(addon, os.path.join(d, "dist"))
            names = sorted(zipfile.ZipFile(zip_path).namelist())
            self.assertEqual(names, ["MyAddon/Core.lua", "MyAddon/MyAddon.toc", "MyAddon/README.md"])

    def test_resolve_addon(self):
        with tempfile.TemporaryDirectory() as d:
            root = os.path.join(d, "AddOns")
            addon = os.path.join(root, "MyAddon")
            write(os.path.join(addon, "MyAddon.toc"), "## Version: 1\n")
            old = os.getcwd()
            try:
                os.chdir(addon)       # a session opened inside the addon folder
                self.assertEqual(os.path.normcase(package.resolve_addon(".", root)), os.path.normcase(addon))
                self.assertEqual(os.path.normcase(package.resolve_addon("MyAddon", root)), os.path.normcase(addon))
                os.chdir(root)
                self.assertEqual(os.path.normcase(package.resolve_addon("MyAddon", root)), os.path.normcase(addon))
            finally:
                os.chdir(old)

    def test_refuses_to_leave_out_a_toc_file(self):
        with tempfile.TemporaryDirectory() as d:
            addon = os.path.join(d, "MyAddon")
            write(os.path.join(addon, "MyAddon.toc"),
                  "## Interface: 16001\n## Version: 1.0.0\n\nCore.lua\ntests\\Checks.lua\n")
            write(os.path.join(addon, "Core.lua"), "local addonName, ns = ...\n")
            write(os.path.join(addon, "tests", "Checks.lua"), "local addonName, ns = ...\n")
            with self.assertRaises(SystemExit) as caught:
                package.build_zip(addon, os.path.join(d, "dist"))
            self.assertIn("tests/Checks.lua", str(caught.exception))
            self.assertFalse(os.path.exists(os.path.join(d, "dist", "MyAddon-1.0.0.zip")))

    def test_checks_the_icon_with_or_without_extension(self):
        with tempfile.TemporaryDirectory() as d:
            addon = os.path.join(d, "MyAddon")
            toc = "## Interface: 16001\n## Version: 1.0.0\n## IconTexture: Interface\\AddOns\\MyAddon\\Media\\Icon\n\nCore.lua\n"
            write(os.path.join(addon, "MyAddon.toc"), toc)
            write(os.path.join(addon, "Core.lua"), "local addonName, ns = ...\n")
            with self.assertRaises(SystemExit):
                package.build_zip(addon, os.path.join(d, "dist"))   # no icon file at all
            write(os.path.join(addon, "Media", "Icon.tga"), "x")
            zip_path, _, _ = package.build_zip(addon, os.path.join(d, "dist"))   # Media/Icon finds Icon.tga
            self.assertIn("MyAddon/Media/Icon.tga", zipfile.ZipFile(zip_path).namelist())

    def test_toc_files_skip_comments_and_client_tokens(self):
        with tempfile.TemporaryDirectory() as d:
            toc = os.path.join(d, "A.toc")
            write(toc, "## Title: A\n# a comment\n\nCore.lua\nUI\\Main.lua\n[Family]\\Extra.lua\nOld.lua [AllowLoadGameType classic]\n")
            self.assertEqual(package.toc_files(toc), ["Core.lua", "UI/Main.lua"])

    def test_refuses_dev_only(self):
        with tempfile.TemporaryDirectory() as d:
            addon = os.path.join(d, "Probe")
            write(os.path.join(addon, "Probe.toc"), "## Version: 1\n## X-Wowf-DevOnly: 1\n")
            with self.assertRaises(SystemExit):
                package.build_zip(addon, os.path.join(d, "dist"))


if __name__ == "__main__":
    unittest.main()
