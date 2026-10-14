"""Shim: runs `python tools/wowf/cli.py probe-report ...` from anywhere inside the workspace."""
import os
import sys

d = os.path.dirname(os.path.abspath(__file__))
while not os.path.isfile(os.path.join(d, "wowf.config.json")):
    parent = os.path.dirname(d)
    if parent == d:
        sys.exit("wowf: workspace root (wowf.config.json) not found")
    d = parent
sys.path.insert(0, os.path.join(d, "tools", "wowf"))
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass
import cli  # noqa: E402

sys.exit(cli.main(["probe-report", *sys.argv[1:]]))
