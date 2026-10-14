"""Download the official standalone luacheck.exe (lunarmodules v1.2.0) into tools/.

  python tools/wowf/setup_luacheck.py

The SHA256 is pinned in tools/luacheck.sha256 (written on first download, verified afterwards).
"""
import hashlib
import os
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config  # noqa: E402

URL = "https://github.com/lunarmodules/luacheck/releases/download/v1.2.0/luacheck.exe"


def main():
    root = config.repo_root()
    exe = os.path.join(root, "tools", "luacheck.exe")
    pin = os.path.join(root, "tools", "luacheck.sha256")
    print(f"downloading {URL}")
    req = urllib.request.Request(URL, headers={"User-Agent": "wowf-tools/1"})
    data = urllib.request.urlopen(req, timeout=60).read()
    digest = hashlib.sha256(data).hexdigest()
    if os.path.isfile(pin):
        want = open(pin, encoding="utf-8").read().split()[0]
        if want != digest:
            raise SystemExit(f"SHA256 mismatch: got {digest}, pinned {want}. Not installing.")
    else:
        with open(pin, "w", encoding="utf-8", newline="\n") as f:
            f.write(f"{digest}  luacheck.exe  (lunarmodules/luacheck v1.2.0)\n")
        print(f"pinned sha256 {digest}")
    with open(exe, "wb") as f:
        f.write(data)
    print(f"installed {exe} ({len(data)} bytes)")


if __name__ == "__main__":
    main()
