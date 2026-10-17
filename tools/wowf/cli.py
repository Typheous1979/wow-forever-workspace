"""wowf command line.  python tools/wowf/cli.py <command> [args]

Commands:
  api update [--no-live]        refresh Blizzard forever-branch cache and rebuild the index
  api build  [--no-live]        rebuild the index from the existing cache
  api show NAME                 full record(s) for an exact name (C_X.Fn, Global, EVENT, Enum.X, SOUNDKIT.X)
  api find REGEX [--kind K]     search names (kinds: fn method event enum const struct ns pred fx rt)
  api events REGEX              search events
  api soundkit REGEX            search SOUNDKIT constants
  api addon NAME                does a Blizzard UI addon load on Forever?
  api diff [REV]                diff committed index vs working copy (or vs REV)
  api builds                    upstream / index / client / version-server builds
  lint ADDON [--json]           Forever lint (see wowf-review)
  deploy ...                    see deploy.py --help
  sv ...                        SavedVariables reader (see savedvars.py --help)
  logs ...                      client logs / crash reports (see client_logs.py --help)
  probe-report [--client K]     ingest the WowfProbe dump
  new NAME [--title ...]        scaffold a new addon (see scaffold.py --help)
  music-catalog fetch|build|show  MusicForever catalog from Forever game tables (see music_catalog.py)
  recipe-catalog fetch|build|show|vendor-merge  BuffettForever recipes and vendor prices (see recipe_catalog.py)
  econ vectors|check            BuffettForever's evaluator: generated test vectors, replay /bf eval (see econ.py)
  make-icon [--out PATH] [--preview PNG]  draw MusicForever's icon (Media/Icon.tga)
  package ADDON                 lint, then zip to dist/<Addon>-<Version>.zip for CurseForge
  doctor                        environment check
"""
import argparse
import json
import os
import subprocess
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import config  # noqa: E402
import index as idx  # noqa: E402


def _out(s=""):
    sys.stdout.write(s + "\n")


def cmd_api(argv):
    p = argparse.ArgumentParser(prog="wowf api")
    p.add_argument("action", choices=["update", "build", "show", "find", "events", "soundkit", "addon", "diff", "builds"])
    p.add_argument("query", nargs="?")
    p.add_argument("--kind", action="append")
    p.add_argument("--no-live", action="store_true")
    p.add_argument("--limit", type=int, default=200)
    a = p.parse_args(argv)
    cfg = config.load()
    root = cfg["_root"]

    if a.action in ("update", "build"):
        if a.action == "update":
            info = idx.update_upstream(cfg)
            _out(f"upstream: {info['build']} {info['commit'][:10]}")
        meta, n_docs, n_fx = idx.build(cfg, compare_live=not a.no_live)
        _out(f"index built: build {meta['build']}, {meta['files']} doc files, {n_docs} doc records, {n_fx} FrameXML records, parse failures {meta['parse_failures']}")
        return 0

    I = idx.Index(root)
    if not I.loaded:
        _out("index missing — run: python tools/wowf/cli.py api update")
        return 2
    if a.action == "builds":
        return cmd_builds(cfg, I)
    if a.action == "diff":
        return cmd_diff(root, a.query)
    if not a.query:
        _out("query required")
        return 2
    if a.action == "show":
        recs = I.lookup(a.query)
        if not recs:
            _out(f"{a.query}: not in the index. Evidence: {I.evidence(a.query)}")
            near = I.find(r"(^|[.:])" + _re_escape(a.query.split('.')[-1]) + "$", limit=10)
            if near:
                _out("did you mean: " + ", ".join(r["id"] for r in near))
            _out(f"safe probe: /run print(type({_probe_expr(a.query)}))")
            return 1
        for r in recs:
            _out(idx.format_record(r))
        if I.rt_meta:
            _out(f"evidence: {I.evidence(a.query)}")
        return 0
    if a.action == "addon":
        r = I.addons.get(a.query)
        if not r:
            _out(f"{a.query}: no such Blizzard addon in the forever branch")
            return 1
        _out(json.dumps(r))
        return 0
    if a.action == "soundkit":
        import re
        rx = re.compile(a.query, re.I)
        for k, v in sorted(I.soundkit.items()):
            if rx.search(k):
                _out(f"{k} = {v}")
        return 0
    kinds = set(a.kind) if a.kind else None
    if a.action == "events":
        kinds = {"event"}
    res = I.find(a.query, kinds, a.limit)
    for r in res:
        _out(idx.format_record(r).splitlines()[0])
    _out(f"-- {len(res)} result(s)" + (" (limit reached)" if len(res) >= a.limit else ""))
    return 0


def _re_escape(s):
    import re
    return re.escape(s)


def _probe_expr(name):
    parts = name.split(".")
    if len(parts) == 1:
        return name
    return " and ".join(".".join(parts[:i + 1]) for i in range(len(parts)))


def version_server(product, region="us"):
    url = config.load()["version_server"].format(product=product)
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "wowf-tools/1"}), timeout=15) as r:
            text = r.read().decode("utf-8", "replace")
    except Exception as e:
        return f"error: {e}"
    for line in text.splitlines():
        cols = line.split("|")
        if cols and cols[0] == region and len(cols) >= 6:
            return cols[5]
    return "?"


def cmd_builds(cfg, I):
    _out(f"index (committed snapshot): {I.meta.get('build')}  commit {I.meta.get('commit', '')[:10]}")
    if os.path.isdir(config.UPSTREAM_DIR):
        info = idx.upstream_info()
        _out(f"upstream cache:              {info['build']}  commit {info['commit'][:10]}")
    if I.rt_meta:
        _out(f"runtime probe:               {I.rt_meta.get('build')}  ({I.rt_meta.get('client')})")
    for key, c in config.discover_clients(cfg).items():
        _out(f"client {key:<8}             {c['build']}  ({c['dir']})")
    for prod in cfg["products"]:
        _out(f"version server {prod:<17} {version_server(prod)}")
    return 0


def cmd_diff(root, rev):
    dd = os.path.relpath(idx.data_dir(root), root).replace(os.sep, "/")
    rev = rev or "HEAD"
    changed = False
    for name in ("api-index.jsonl", "framexml.jsonl"):
        path = f"{dd}/{name}"
        old = subprocess.run(["git", "show", f"{rev}:{path}"], cwd=root, capture_output=True, text=True, encoding="utf-8")
        if old.returncode:
            _out(f"{name}: no committed version at {rev}")
            continue
        def keyed(text):
            out = {}
            for line in text.splitlines():
                r = json.loads(line)
                if r.get("k") != "meta":
                    out[(r["k"], r["id"])] = r
                else:
                    out[("meta", "")] = r
            return out
        a = keyed(old.stdout)
        b = keyed(open(os.path.join(root, path), encoding="utf-8").read())
        _out(f"== {name}: {a.get(('meta',''), {}).get('build')} -> {b.get(('meta',''), {}).get('build')}")
        for k in sorted(set(a) | set(b)):
            if k[0] == "meta":
                continue
            if k not in a:
                _out(f"+ {k[0]} {k[1]}"); changed = True
            elif k not in b:
                _out(f"- {k[0]} {k[1]}"); changed = True
            elif a[k] != b[k]:
                _out(f"~ {k[0]} {k[1]}"); changed = True
    if not changed:
        _out("no record changes")
    return 0


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv or argv[0] in ("-h", "--help", "help"):
        _out(__doc__)
        return 0
    cmd, rest = argv[0], argv[1:]
    if cmd == "api":
        return cmd_api(rest)
    if cmd == "lint":
        import lint
        return lint.main(rest)
    if cmd == "deploy":
        import deploy
        return deploy.main(rest)
    if cmd == "sv":
        import savedvars
        return savedvars.main(rest)
    if cmd == "logs":
        import client_logs
        return client_logs.main(rest)
    if cmd == "probe-report":
        import probe_report
        return probe_report.main(rest)
    if cmd == "new":
        import scaffold
        return scaffold.main(rest)
    if cmd == "music-catalog":
        import music_catalog
        return music_catalog.main(rest)
    if cmd == "recipe-catalog":
        import recipe_catalog
        return recipe_catalog.main(rest)
    if cmd == "econ":
        import econ
        return econ.main(rest)
    if cmd == "make-icon":
        import make_icon
        return make_icon.main(rest)
    if cmd == "package":
        import package
        return package.main(rest)
    if cmd == "doctor":
        import doctor
        return doctor.main(rest)
    _out(f"unknown command {cmd!r}\n" + __doc__)
    return 2


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    sys.exit(main())
