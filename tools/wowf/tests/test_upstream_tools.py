import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import config  # noqa: E402
import doctor  # noqa: E402
import index  # noqa: E402
import music_catalog  # noqa: E402
import recipe_catalog  # noqa: E402


def git(cwd, *args):
    r = subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.com", *args], cwd=cwd,
                       capture_output=True, text=True)
    if r.returncode:
        raise AssertionError(f"git {' '.join(args)}: {r.stderr}")
    return r.stdout


def commit_docs(repo, names):
    docs = os.path.join(repo, index.DOC_DIR)
    os.makedirs(docs, exist_ok=True)
    for f in os.listdir(docs):
        os.remove(os.path.join(docs, f))
    for name in names:
        with open(os.path.join(docs, name), "w") as f:
            f.write("-- doc\n")
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", "docs")


class LiveCompareTests(unittest.TestCase):
    """The live branch is force-pushed upstream; the comparison must still follow it (lost 70450's forever_only)."""

    def test_follows_a_force_pushed_live_branch(self):
        with tempfile.TemporaryDirectory() as tmp:
            origin, cache = os.path.join(tmp, "origin"), os.path.join(tmp, "cache")
            os.makedirs(origin)
            git(origin, "init", "-q", "-b", "live")
            commit_docs(origin, ["OldDocumentation.lua"])
            git(tmp, "clone", "-q", "--no-local", origin, cache)
            git(cache, "fetch", "-q", "origin", "live:refs/remotes/origin/live")
            # upstream rewrites live: the new tip doesn't descend from the old one
            git(origin, "checkout", "-q", "--orphan", "rewritten")
            commit_docs(origin, ["NewDocumentation.lua"])
            git(origin, "branch", "-q", "-D", "live")
            git(origin, "branch", "-q", "-m", "live")
            cfg = {"upstream": {"compare_branch": "live"}}
            with mock.patch.object(config, "UPSTREAM_DIR", cache):
                self.assertEqual(index.live_doc_files(cfg), {"NewDocumentation.lua"})


class SmallToolFixes(unittest.TestCase):
    def test_music_catalog_accepts_a_header_not_starting_with_id(self):
        # WMOAreaTable's header starts AreaName_lang,ID,...: a startswith("ID,") check rejected it on 70862.
        with tempfile.TemporaryDirectory() as tmp:
            body = b"AreaName_lang,ID,WMOID\nStormwind,1,2\n"
            with mock.patch.object(music_catalog, "MUSIC_DIR", tmp), \
                    mock.patch.object(music_catalog, "TABLES", ["WMOAreaTable"]), \
                    mock.patch.object(music_catalog, "_get", return_value=(body, None, None)), \
                    mock.patch.object(music_catalog.time, "sleep"):
                music_catalog.fetch_tables("1.2.3", log=lambda *_: None)
                self.assertTrue(os.path.isfile(os.path.join(music_catalog.csv_dir("1.2.3"), "WMOAreaTable.csv")))

    def test_recipe_catalog_defaults_to_the_live_build(self):
        self.assertEqual(recipe_catalog.DEFAULT_BUILD, "1.60.1.70888")

    def test_doctor_no_longer_announces_the_stress_test(self):
        with open(doctor.__file__, encoding="utf-8") as f:
            self.assertNotIn("stress test Oct 19", f.read())


if __name__ == "__main__":
    unittest.main()
