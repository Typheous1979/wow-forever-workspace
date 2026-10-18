import contextlib
import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import publish  # noqa: E402


class PrivateHitsTests(unittest.TestCase):
    def test_finds_each_kind_and_counts_only(self):
        text = ("path C:\\Users\\Bob\\x and C:\\\\Users\\\\Bob\\\\y, /c/Users/Bob/z, AppData\\Local, account 123456#1, "
                "mail bob@gmail.com, SecretAccountName")
        hits = publish.private_hits(text, {"SecretAccountName"})
        self.assertEqual(hits["this machine's paths or account names"], 1)
        self.assertEqual(hits["Windows user paths"], 2)
        self.assertEqual(hits["POSIX user paths"], 1)
        self.assertEqual(hits["AppData"], 1)
        self.assertEqual(hits["account-ID shapes"], 1)
        self.assertEqual(hits["email addresses"], 1)

    def test_noreply_and_your_own_email_are_fine(self):
        text = ("Co-Authored-By: Claude <noreply@anthropic.com>\nAuthor: me <me@mysite.dev>\n%LOCALAPPDATA%\\wowf\n"
                "+@unittest.skipUnless(shutil.which(\"git\"))\ngit config user.email test@example.com\n")
        self.assertEqual(publish.private_hits(text, set(), "me@mysite.dev"), {})
        self.assertEqual(publish.private_hits("someone@mysite.dev", set(), "me@mysite.dev"), {"email addresses": 1})


def _git_has_subtree():
    if not shutil.which("git"):
        return False
    r = subprocess.run(["git", "subtree", "-h"], capture_output=True, text=True)
    return "usage" in (r.stdout + r.stderr).lower()


@unittest.skipUnless(_git_has_subtree(), "git subtree is not available")
class SplitTests(unittest.TestCase):
    def _repo(self, d):
        def git(*args):
            return subprocess.run(["git", *args], cwd=d, capture_output=True, check=True, text=True).stdout
        git("init", "-q")
        git("config", "user.email", "test@example.org")
        git("config", "user.name", "test")
        git("config", "core.autocrlf", "false")
        addon = os.path.join(d, "MyAddon")
        os.makedirs(addon)
        with open(os.path.join(addon, "MyAddon.toc"), "w", encoding="utf-8", newline="\n") as f:
            f.write("## Interface: 16001\n\nCore.lua\n")
        with open(os.path.join(addon, "Core.lua"), "w", encoding="utf-8", newline="\n") as f:
            f.write("local addonName, ns = ...\n")
        os.makedirs(os.path.join(d, "tools"))
        with open(os.path.join(d, "tools", "other.py"), "w", encoding="utf-8", newline="\n") as f:
            f.write("print('not the addon')\n")
        git("add", ".")
        git("commit", "-q", "-m", "MyAddon: first")
        return git, addon

    def test_splits_the_addon_alone_and_stops_before_pushing(self):
        with tempfile.TemporaryDirectory() as d:
            git, addon = self._repo(d)
            with contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(publish.main([addon]), 0)
            self.assertIn("found nothing private", out.getvalue())
            files = git("ls-tree", "--name-only", "publish/myaddon").split()
            self.assertEqual(sorted(files), ["Core.lua", "MyAddon.toc"])

    def test_refuses_uncommitted_changes(self):
        with tempfile.TemporaryDirectory() as d:
            _, addon = self._repo(d)
            with open(os.path.join(addon, "Core.lua"), "a", encoding="utf-8") as f:
                f.write("-- more\n")
            with contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(publish.main([addon]), 1)
            self.assertIn("uncommitted changes", out.getvalue())

    def test_stops_on_a_private_string_in_the_history(self):
        with tempfile.TemporaryDirectory() as d:
            git, addon = self._repo(d)
            with open(os.path.join(addon, "Core.lua"), "a", encoding="utf-8", newline="\n") as f:
                f.write("-- C:\\Users\\Bob\\Desktop\n")
            git("commit", "-q", "-am", "MyAddon: a path")
            with contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(publish.main([addon]), 1)
            self.assertIn("Windows user paths: 1", out.getvalue())

    def test_scans_a_range_alone(self):
        with tempfile.TemporaryDirectory() as d:
            git, addon = self._repo(d)
            with open(os.path.join(d, "tools", "other.py"), "a", encoding="utf-8", newline="\n") as f:
                f.write("# bob@mysite.dev\n")
            git("commit", "-q", "-am", "tools: a mail")
            here = os.getcwd()
            try:
                os.chdir(d)
                with contextlib.redirect_stdout(io.StringIO()) as out:
                    self.assertEqual(publish.main(["--scan", "HEAD~1..HEAD"]), 1)
                    self.assertEqual(publish.main(["--scan", "HEAD~1"]), 0)
            finally:
                os.chdir(here)
            self.assertIn("email addresses: 1", out.getvalue())


if __name__ == "__main__":
    unittest.main()
