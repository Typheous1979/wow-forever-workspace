"""Workspace configuration and client discovery.

- repo root: nearest ancestor containing wowf.config.json
- wowf.config.json (committed) + wowf.local.json (gitignored, machine paths)
- clients: auto-discovered `<root>\\_*_\\` folders containing Wow*.exe, merged
  with any explicit `clients` in wowf.local.json.
"""
import glob
import json
import os
import re

CACHE_DIR = os.path.join(os.environ.get("LOCALAPPDATA") or os.path.expanduser("~"), "wowf")
UPSTREAM_DIR = os.path.join(CACHE_DIR, "wow-ui-source")
RUNTIME_DIR = os.path.join(CACHE_DIR, "runtime")


def repo_root(start=None):
    d = os.path.abspath(start or os.getcwd())
    here = os.path.dirname(os.path.abspath(__file__))
    for base in (d, here):
        cur = base
        while True:
            if os.path.isfile(os.path.join(cur, "wowf.config.json")):
                return cur
            parent = os.path.dirname(cur)
            if parent == cur:
                break
            cur = parent
    raise SystemExit("wowf: could not find wowf.config.json above " + d)


def load(root=None):
    root = root or repo_root()
    with open(os.path.join(root, "wowf.config.json"), encoding="utf-8") as f:
        cfg = json.load(f)
    local_path = os.path.join(root, "wowf.local.json")
    local = {}
    if os.path.isfile(local_path):
        with open(local_path, encoding="utf-8") as f:
            local = json.load(f)
    cfg["_root"] = root
    cfg["_local"] = local
    return cfg


def save_local(cfg, local):
    path = os.path.join(cfg["_root"], "wowf.local.json")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(local, f, indent=2)
        f.write("\n")
    cfg["_local"] = local


def read_build_info(client_dir):
    """Best-effort read of the client's build.

    Returns e.g. "1.60.1.70338" or None. Uses `.build.info` in the install
    root (pipe-separated table with a Version column), falling back to the
    last `WoW Version` line in Logs/Sound.log.
    """
    flavor = None
    fi = os.path.join(client_dir, ".flavor.info")
    if os.path.isfile(fi):
        with open(fi, encoding="utf-8", errors="replace") as fh:
            lines = [l.strip() for l in fh if l.strip()]
        flavor = lines[-1] if lines else None
    root = os.path.dirname(client_dir)
    bi = os.path.join(root, ".build.info")
    if os.path.isfile(bi):
        with open(bi, encoding="utf-8", errors="replace") as fh:
            rows = [l.rstrip("\r\n").split("|") for l in fh if l.strip()]
        if rows:
            hdr = [h.split("!")[0].strip().lower() for h in rows[0]]
            for r in rows[1:]:
                rec = dict(zip(hdr, r))
                if flavor and rec.get("product") and rec.get("product") != flavor:
                    continue
                if rec.get("version"):
                    return rec["version"]
    log = os.path.join(client_dir, "Logs", "Sound.log")
    if os.path.isfile(log):
        last = None
        for line in open(log, encoding="utf-8", errors="replace"):
            m = re.search(r"WoW Version (\d+\.\d+\.\d+) \((\d+)\)", line)
            if m:
                last = f"{m.group(1)}.{m.group(2)}"
        return last
    return None


def discover_clients(cfg):
    """Return {key: {"dir":..., "product":..., "addons":..., "build":...}}.

    key is "beta" for _classic_beta_, "forever" for _forever_, else folder name.
    """
    found = {}
    products = cfg.get("products", {})
    folder_to_product = {v["folder"]: k for k, v in products.items()}
    roots = list(cfg.get("_local", {}).get("client_search_roots", [])) + cfg.get("client_search_roots", [])
    for root in roots:
        for d in sorted(glob.glob(os.path.join(root, "_*_"))):
            if not glob.glob(os.path.join(d, "Wow*.exe")):
                continue
            folder = os.path.basename(d)
            product = folder_to_product.get(folder)
            if product is None:
                continue  # only Forever products (beta, wowf) are managed
            key = "beta" if folder == "_classic_beta_" else "forever" if folder == "_forever_" else folder.strip("_")
            if key in found:
                continue
            found[key] = {
                "dir": d,
                "product": product,
                "addons": os.path.join(d, "Interface", "AddOns"),
                "build": read_build_info(d),
            }
    for key, d in cfg.get("_local", {}).get("clients", {}).items():
        found[key] = {"dir": d, "product": key, "addons": os.path.join(d, "Interface", "AddOns"), "build": read_build_info(d)}
    return found


def pick_clients(cfg, which):
    clients = discover_clients(cfg)
    if which in (None, "all"):
        return clients
    if which not in clients:
        raise SystemExit(f"wowf: client '{which}' not found. Known: {', '.join(clients) or 'none'}")
    return {which: clients[which]}
