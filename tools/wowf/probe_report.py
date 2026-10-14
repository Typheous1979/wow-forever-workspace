"""Ingest a WowfProbe dump (WowfProbeDB SavedVariables) into the runtime layer.

  python tools/wowf/cli.py probe-report [--client beta|forever] [--no-write]

Reads <client>\\WTF\\Account\\*\\SavedVariables\\WowfProbe.lua (read-only), prints the
client facts, compares runtime names with the documented index, and writes:
  .claude/skills/wowf-api/data/runtime-surface.jsonl   committed: function/table/C_ member names
  %LOCALAPPDATA%\\wowf\\runtime\\<build>.json            local: full dump incl. string-global names
"""
import argparse
import json
import os

import config
import index as idx
from savedvars import find_sv_files, load_sv
from lua_literal import to_jsonable


def latest_run(cfg, which):
    best = None
    for key, c in config.pick_clients(cfg, which).items():
        for scope, label, path in find_sv_files(c["dir"], "WowfProbe"):
            db = load_sv(path).get("WowfProbeDB") or {}
            runs = db.get("runs") or []
            if isinstance(runs, dict):
                runs = [runs[k] for k in sorted(runs)]
            for run in runs:
                t = (run.get("meta") or {}).get("time") or 0
                if best is None or t > best[0]:
                    best = (t, key, path, run)
    return best


def _lines(s):
    return [x for x in (s or "").split("\n") if x] if isinstance(s, str) and not s.startswith("<") else []


def surface_names(run):
    names = set()
    quick = run.get("quick") or {}
    for ns, members in (quick.get("namespaces") or {}).items():
        names.add(ns)
        for m in _lines(members):
            names.add(f"{ns}.{m}")
    for lib, members in (quick.get("libs") or {}).items():
        names.add(lib)
        for m in _lines(members):
            names.add(f"{lib}.{m}")
    full = run.get("full") or {}
    for t in ("function", "table", "userdata"):
        for n in _lines(full.get(t)):
            names.add(n)
    for e, members in (full.get("enum") or {}).items():
        names.add("Enum." + e)
        for m in _lines(members):
            names.add(f"Enum.{e}.{m}")
    for name, typ in ((run.get("meta") or {}).get("globals") or {}).items():
        if typ not in ("nil", None):
            names.add(name)
    return names


def main(argv):
    p = argparse.ArgumentParser(prog="wowf probe-report")
    p.add_argument("--client", default=None)
    p.add_argument("--no-write", action="store_true")
    a = p.parse_args(argv)
    cfg = config.load()
    best = latest_run(cfg, a.client)
    if not best:
        print("no WowfProbe data yet. Deploy it (deploy WowfProbe), log in, type /wowfprobe, accept Reload.")
        return 1
    _, client_key, path, run = best
    m = run.get("meta") or {}
    print(f"probe from {client_key}: {path}")
    print(f"  build {m.get('version')}.{m.get('build')}  interface {m.get('interface')}  mode {run.get('mode')}")
    print(f"  WOW_PROJECT_ID {m.get('WOW_PROJECT_ID')}  CAMELOT {m.get('WOW_PROJECT_CAMELOT')}  MAINLINE {m.get('WOW_PROJECT_MAINLINE')}  CLASSIC {m.get('WOW_PROJECT_CLASSIC')}")
    print(f"  TOC [Family]/[Game] -> {m.get('tocFamily')}/{m.get('tocGame')}   locale {m.get('locale')}  region {m.get('region')} {m.get('regionName')}")
    print(f"  preset {m.get('foreverPreset')}  hardcore {m.get('hardcore')}  selfFound {m.get('selfFoundAllowed')}  secretRestrictions {m.get('secretRestrictions')}")
    print(f"  secrets: health {m.get('healthSecret')}  healthMax {m.get('healthMaxSecret')}  name {m.get('nameSecret')}  (inCombat {m.get('inCombat')}, instance {m.get('inInstance')})")
    g = m.get("globals") or {}
    print("  globals: " + ", ".join(f"{k}={v}" for k, v in sorted(g.items())))
    if isinstance(run.get("popup"), dict):
        print(f"  last reload popup: {json.dumps(to_jsonable(run['popup']))}")
    cv = m.get("cvars") or {}
    print("  cvars: " + ", ".join(f"{k}={v}" for k, v in sorted(cv.items())))
    q = run.get("queries") or {}
    for kind in ("functions", "events", "addons"):
        for k, v in sorted((q.get(kind) or {}).items()):
            print(f"  query {kind[:-1]} {k}: {json.dumps(to_jsonable(v))}")

    names = surface_names(run)
    I = idx.Index(cfg["_root"])
    doc_ns = {n for n in I.namespaces() if n.startswith("C_")}  # docs also cover math/string/table
    rt_ns = {n for n in names if n.startswith("C_") and "." not in n}
    print(f"\nC_ namespaces: documented {len(doc_ns)}, runtime {len(rt_ns)}")
    missing = sorted(doc_ns - rt_ns)
    extra = sorted(rt_ns - doc_ns)
    if missing:
        print("  documented but NOT present: " + ", ".join(missing))
    if extra:
        print("  present but undocumented: " + ", ".join(extra))
    build = f"{m.get('version')}.{m.get('build')}"
    if a.no_write:
        return 0
    os.makedirs(config.RUNTIME_DIR, exist_ok=True)
    local_path = os.path.join(config.RUNTIME_DIR, f"{build}.json")
    with open(local_path, "w", encoding="utf-8") as f:
        json.dump(to_jsonable(run), f)
    meta = {"k": "meta", "schema": 1, "build": build, "client": client_key, "mode": run.get("mode"),
            "names": len(names), "interface": m.get("interface")}
    recs = [{"k": "rt", "id": n} for n in names]
    out = os.path.join(idx.data_dir(cfg["_root"]), "runtime-surface.jsonl")
    if os.path.isfile(out) and run.get("mode") != "full":
        # keep full-mode names from an earlier probe of the same build
        prev = idx.Index(cfg["_root"])
        if prev.rt_meta.get("build") == build and prev.rt_meta.get("mode") == "full":
            recs += [{"k": "rt", "id": n} for n in prev.rt - names]
            meta["mode"] = "full+quick"
    idx.write_jsonl(out, meta, recs)
    print(f"\nwrote {out} ({len(recs)} names) and {local_path}")
    return 0
