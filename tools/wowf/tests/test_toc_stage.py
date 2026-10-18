import contextlib
import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import toc_stage  # noqa: E402

COMMITTED = "## Interface: 16001\n## Version: 0.8.0\n## SavedVariables: MyDB\n\nCore.lua\nUI\\Main.lua\n"
WORKING = "## Interface: 16001\n## Version: 1.0.0\n## SavedVariables: MyDB\n\nCore.lua\nPricing\\Buy.lua\nUI\\Main.lua\n"


class MergeTests(unittest.TestCase):
    def test_keeps_the_committed_header_and_takes_the_new_file_lines(self):
        text, differs = toc_stage.merge(COMMITTED, WORKING)
        self.assertEqual(text, "## Interface: 16001\n## Version: 0.8.0\n## SavedVariables: MyDB\n\n"
                               "Core.lua\nPricing\\Buy.lua\nUI\\Main.lua\n")
        self.assertEqual(differs, ["- ## Version: 0.8.0", "+ ## Version: 1.0.0"])

    def test_a_comment_between_files_belongs_to_the_file_list(self):
        working = WORKING.replace("UI\\Main.lua", "# the window\nUI\\Main.lua")
        text, _ = toc_stage.merge(COMMITTED, working)
        self.assertIn("Pricing\\Buy.lua\n# the window\nUI\\Main.lua\n", text)
        self.assertIn("## Version: 0.8.0\n", text)

    def test_no_trailing_newline_stays_that_way(self):
        text, differs = toc_stage.merge(COMMITTED, COMMITTED.rstrip("\n"))
        self.assertFalse(text.endswith("\n"))
        self.assertEqual(differs, [])


@unittest.skipUnless(shutil.which("git"), "git is not installed")
class IndexTests(unittest.TestCase):
    def test_stages_the_file_list_and_leaves_the_working_copy(self):
        with tempfile.TemporaryDirectory() as d:
            def git(*args):
                return subprocess.run(["git", *args], cwd=d, capture_output=True, check=True).stdout.decode()
            git("init", "-q")
            git("config", "user.email", "test@example.com")
            git("config", "user.name", "test")
            git("config", "core.autocrlf", "false")
            addon = os.path.join(d, "MyAddon")
            os.makedirs(addon)
            toc = os.path.join(addon, "MyAddon.toc")
            with open(toc, "w", encoding="utf-8", newline="\n") as f:
                f.write(COMMITTED)
            git("add", ".")
            git("commit", "-q", "-m", "first")
            with open(toc, "w", encoding="utf-8", newline="\n") as f:
                f.write(WORKING)
            with contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(toc_stage.main([addon]), 0)
            self.assertIn("header kept as committed: + ## Version: 1.0.0", out.getvalue())
            staged = git("show", ":MyAddon/MyAddon.toc")
            self.assertIn("## Version: 0.8.0", staged)
            self.assertIn("Pricing\\Buy.lua", staged)
            with open(toc, encoding="utf-8") as f:
                self.assertIn("## Version: 1.0.0", f.read())


if __name__ == "__main__":
    unittest.main()
