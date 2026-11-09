import contextlib
import io
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import client_logs  # noqa: E402
import config  # noqa: E402
import deploy  # noqa: E402


def write(path, text=""):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


class DefaultClientTests(unittest.TestCase):
    """The client `logs` and `deploy` use when --client isn't given."""

    def test_prefers_the_launch_client(self):
        self.assertEqual(config.default_client({"beta": {}, "forever": {}}), "forever")

    def test_beta_when_it_is_the_only_forever_client(self):
        self.assertEqual(config.default_client({"beta": {}}), "beta")

    def test_any_single_client(self):
        self.assertEqual(config.default_client({"ptr": {}}), "ptr")

    def test_none_without_clients(self):
        self.assertIsNone(config.default_client({}))


class LaunchClientOnlyTests(unittest.TestCase):
    """A workspace whose only client is the launch client (_forever_), as after the beta closed (2026-11)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="wowf test ")  # space in path on purpose
        base = self.tmp.name
        self.root = os.path.join(base, "repo")
        wow = os.path.join(base, "World of Warcraft")
        client = os.path.join(wow, "_forever_")
        write(os.path.join(client, "Wow.exe"))
        os.makedirs(os.path.join(client, "Interface", "AddOns"))
        write(os.path.join(client, "Logs", "General.log"),
              "11/9 16:10:18.767  [E][Lua] Lua Error: x.lua:1: execution tainted by 'MyAddon'\n"
              "11/9 16:10:19.000  [N][Console] Weather changed to 0\n")
        write(os.path.join(self.root, "wowf.config.json"), json.dumps({
            "schema": 1,
            "products": {"wow_classic_beta": {"folder": "_classic_beta_"}, "wowf": {"folder": "_forever_"}},
            "client_search_roots": [wow],
        }))
        write(os.path.join(self.root, "MyAddon", "MyAddon.toc"), "## Interface: 16001\n\nCore.lua\n")
        write(os.path.join(self.root, "MyAddon", "Core.lua"), "local addonName, ns = ...\n")
        self.link = os.path.join(client, "Interface", "AddOns", "MyAddon")
        self.cwd = os.getcwd()
        os.chdir(self.root)   # config.load() finds the workspace from the working directory

    def tearDown(self):
        os.chdir(self.cwd)
        if os.path.isjunction(self.link):
            os.rmdir(self.link)   # unlink only: never delete through a junction
        self.tmp.cleanup()

    def run_tool(self, main, argv):
        out = io.StringIO()
        try:
            with contextlib.redirect_stdout(out):
                main(argv)
        except SystemExit as e:
            self.fail(f"{' '.join(argv)} exited: {e}")
        return out.getvalue()

    def test_logs_read_the_installed_client(self):
        out = self.run_tool(client_logs.main, ["show", "General", "--grep", "Lua Error"])
        self.assertIn("execution tainted by 'MyAddon'", out)
        self.assertNotIn("Weather", out)

    def test_deploy_links_into_the_installed_client(self):
        self.run_tool(deploy.main, ["MyAddon"])
        self.assertTrue(os.path.isjunction(self.link))


if __name__ == "__main__":
    unittest.main()
