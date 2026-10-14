"""WoW Forever API index: Blizzard docs + FrameXML scan + runtime probe.

Files (committed, sorted JSONL, one meta line first):
  .claude/skills/wowf-api/data/api-index.jsonl      docs layer (k: ns, fn, method, event, enum, const, struct, pred)
  .claude/skills/wowf-api/data/framexml.jsonl       FrameXML layer (k: fx, soundkit, addon)
  .claude/skills/wowf-api/data/runtime-surface.jsonl runtime names from WowfProbe (optional)
"""
import glob
import json
import os
import re
import subprocess

import config
from lua_literal import parse_doc_chunk, LuaRef
from lua_lexer import LuaSyntaxError

SCHEMA = 1
DOC_DIR = os.path.join("Interface", "AddOns", "Blizzard_APIDocumentationGenerated")
FOREVER_TYPES = {"camelot", "forever", "mainline"}
# Documented calls observed to crash the client (access violation; pcall cannot catch).
CRASHES = {
    "C_Housing.GetMaxHouseLevel": "Access violation on build 69913 (community fact sheet, justadakaje/wow-addons). [F-crash]",
}
_BASE_KEYS = {"Name", "Type", "Arguments", "Returns", "Documentation", "LiteralName", "Payload", "Fields"}


def data_dir(root):
    return os.path.join(root, ".claude", "skills", "wowf-api", "data")


def _git(args, cwd):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, encoding="utf-8", errors="replace")


# ---------------------------------------------------------------- update
def update_upstream(cfg, log=print):
    """Clone or refresh the shallow, blobless, sparse forever-branch cache."""
    up = cfg["upstream"]
    d = config.UPSTREAM_DIR
    os.makedirs(config.CACHE_DIR, exist_ok=True)
    if not os.path.isdir(os.path.join(d, ".git")):
        log(f"cloning {up['repo']} ({up['branch']}) into {d} ...")
        r = _git(["clone", "--depth", "1", "--filter=blob:none", "--single-branch", "--branch", up["branch"], "--no-checkout", up["repo"], d], config.CACHE_DIR)
        if r.returncode:
            raise SystemExit(r.stderr)
        _git(["sparse-checkout", "set", "--no-cone", "/version.txt", "/Interface/AddOns/**/*.lua", "/Interface/AddOns/**/*.toc", "/Interface/AddOns/**/*.xml"], d)
        r = _git(["checkout", up["branch"]], d)
    else:
        log("fetching latest forever build ...")
        r = _git(["fetch", "--depth", "1", "origin", up["branch"]], d)
        if r.returncode:
            raise SystemExit(r.stderr)
        r = _git(["reset", "--hard", "FETCH_HEAD"], d)
    if r.returncode:
        raise SystemExit(r.stderr)
    return upstream_info()


def upstream_info():
    d = config.UPSTREAM_DIR
    build = _git(["show", "HEAD:version.txt"], d).stdout.strip()
    sha = _git(["rev-parse", "HEAD"], d).stdout.strip()
    return {"build": build, "commit": sha}


def live_doc_files(cfg):
    """Doc file names on the comparison branch (tree only, no blobs)."""
    d = config.UPSTREAM_DIR
    br = cfg["upstream"].get("compare_branch", "live")
    r = _git(["fetch", "--depth", "1", "--filter=blob:none", "origin", f"{br}:refs/remotes/origin/{br}"], d)
    if r.returncode:
        return None
    r = _git(["ls-tree", "--name-only", f"origin/{br}", DOC_DIR.replace(os.sep, "/") + "/"], d)
    return {os.path.basename(p) for p in r.stdout.split()} if r.returncode == 0 else None


# ---------------------------------------------------------------- docs layer
def _field(x):
    out = {"n": x.get("Name"), "t": x.get("Type")}
    if x.get("Nilable"):
        out["o"] = 1
    if "Default" in x:
        out["d"] = x["Default"] if not isinstance(x["Default"], LuaRef) else str(x["Default"])
    if x.get("InnerType"):
        out["it"] = x["InnerType"]
    if x.get("Mixin"):
        out["mx"] = x["Mixin"]
    for k in ("ConditionalSecret", "NeverSecret", "SecretValue", "ConditionalSecretContents", "NeverSecretContents"):
        if x.get(k):
            out.setdefault("sec", []).append(k)
    if x.get("StrideIndex"):
        out["stride"] = x["StrideIndex"]
    return out


def _flags(t):
    f = {}
    for k, v in t.items():
        if k in _BASE_KEYS:
            continue
        f[k] = [str(x) for x in v] if isinstance(v, list) and all(isinstance(x, (str, LuaRef)) for x in v) else (str(v) if isinstance(v, LuaRef) else v)
    return f


def _secret_class(fn):
    if fn.get("SecretReturns"):
        return "always"
    if any(k.startswith(("SecretWhen", "SecretIn", "SecretOn")) and fn.get(k) for k in fn):
        return "conditional"
    for r in fn.get("Returns") or []:
        if isinstance(r, dict) and (r.get("ConditionalSecret") or r.get("SecretValue")):
            return "conditional"
    if fn.get("SecretReturnsForAspect"):
        return "conditional"
    return "never"


def build_docs(cfg, forever_only_files=None, log=print):
    d = os.path.join(config.UPSTREAM_DIR, DOC_DIR)
    files = sorted(glob.glob(os.path.join(d, "*Documentation.lua")))
    recs, failures = [], []
    for path in files:
        fname = os.path.basename(path)
        try:
            with open(path, "rb") as fh:
                _, t = parse_doc_chunk(fh.read())
        except LuaSyntaxError as e:
            failures.append(f"{fname}: {e}")
            continue
        if not isinstance(t, dict):
            continue
        fo = forever_only_files is not None and fname not in forever_only_files
        typ = t.get("Type")
        ns = t.get("Namespace")
        env = t.get("Environment")
        common = {"file": fname}
        if fo:
            common["forever_only"] = True
        if typ == "System" and ns:
            recs.append({"k": "ns", "id": ns, "sys": t.get("Name"), **({"env": env} if env else {}), **common})
        for fn in t.get("Functions") or []:
            if not isinstance(fn, dict) or not fn.get("Name"):
                continue
            if typ == "ScriptObject":
                rid, kind = f"{t.get('Name')}:{fn['Name']}", "method"
            elif ns:
                rid, kind = f"{ns}.{fn['Name']}", "fn"
            else:
                rid, kind = fn["Name"], "fn"
            rec = {"k": kind, "id": rid}
            if kind == "fn" and not ns:
                rec["global"] = True
            if kind == "method":
                rec["widget"] = t.get("Name")
            if ns:
                rec["ns"] = ns
            if env:
                rec["env"] = env
            args = [_field(a) for a in fn.get("Arguments") or [] if isinstance(a, dict)]
            rets = [_field(a) for a in fn.get("Returns") or [] if isinstance(a, dict)]
            if args:
                rec["args"] = args
            if rets:
                rec["ret"] = rets
            fl = _flags(fn)
            if fl:
                rec["f"] = fl
            rec["secret"] = _secret_class(fn)
            if env == "SecureOnly":
                rec["secure_only"] = True
            if fn.get("HasRestrictions"):
                rec["restricted"] = True
            if fn.get("IsProtectedFunction"):
                rec["protected"] = True
            if rid in CRASHES:
                rec["crashes"] = CRASHES[rid]
            if fn.get("Documentation"):
                rec["doc"] = " ".join(str(x) for x in fn["Documentation"]) if isinstance(fn["Documentation"], list) else str(fn["Documentation"])
            recs.append({**rec, **common})
        for ev in t.get("Events") or []:
            if not isinstance(ev, dict) or not ev.get("LiteralName"):
                continue
            rec = {"k": "event", "id": ev["LiteralName"], "sys": t.get("Name")}
            pl = [_field(a) for a in ev.get("Payload") or [] if isinstance(a, dict)]
            if pl:
                rec["payload"] = pl
            fl = _flags(ev)
            if fl:
                rec["f"] = fl
            if ev.get("HasRestrictions"):
                rec["restricted"] = True
            recs.append({**rec, **common})
        for tb in t.get("Tables") or []:
            if not isinstance(tb, dict) or not tb.get("Name"):
                continue
            tt = tb.get("Type")
            if tt == "Enumeration":
                vals = {f["Name"]: f.get("EnumValue") for f in tb.get("Fields") or [] if isinstance(f, dict)}
                recs.append({"k": "enum", "id": "Enum." + tb["Name"], "v": vals, **common})
            elif tt == "Constants":
                vals = {}
                for f in tb.get("Values") or []:
                    if isinstance(f, dict):
                        v = f.get("Value")
                        vals[f.get("Name")] = str(v) if isinstance(v, LuaRef) else v
                recs.append({"k": "const", "id": "Constants." + tb["Name"], "v": vals, **common})
            elif tt in ("Structure", "CallbackType"):
                rec = {"k": "struct" if tt == "Structure" else "callback", "id": tb["Name"]}
                fields = [_field(a) for a in (tb.get("Fields") or tb.get("Arguments") or []) if isinstance(a, dict)]
                if fields:
                    rec["fields"] = fields
                recs.append({**rec, **common})
        for pr in t.get("Predicates") or []:
            if isinstance(pr, dict) and pr.get("Name"):
                rec = {"k": "pred", "id": pr["Name"], "kind": pr.get("Type")}
                if pr.get("FailureMode"):
                    rec["failure"] = str(pr["FailureMode"])
                if pr.get("Documentation"):
                    rec["doc"] = " ".join(str(x) for x in pr["Documentation"]) if isinstance(pr["Documentation"], list) else str(pr["Documentation"])
                recs.append({**rec, **common})
    return recs, failures, len(files)


# ---------------------------------------------------------------- FrameXML layer
_TOC_DIRECTIVE = re.compile(r"^##\s*([\w-]+)\s*:\s*(.*)$")
_INLINE = re.compile(r"\[(AllowLoadGameType|ExcludeLoadGameType)\s+([^\]]*)\]", re.I)
_FN_GLOBAL = re.compile(r"^function\s+([A-Za-z_]\w*)\s*\(")
_FN_MEMBER = re.compile(r"^function\s+([A-Za-z_]\w*)[.:]([A-Za-z_]\w*)\s*\(")
_VAR_GLOBAL = re.compile(r"^([A-Za-z_]\w*)\s*=(?!=)")
_VAR_MEMBER = re.compile(r"^([A-Za-z_]\w*)\.([A-Za-z_]\w*)\s*=(?!=)")
_MIXINISH = re.compile(r"(Mixin|Template|Mixins?_\w+)$")

# C functions that exist on Forever but are absent from the generated docs and
# not defined in FrameXML Lua. Each entry: name -> evidence. Verified/extended by
# the WowfProbe runtime layer.
UNDOCUMENTED_C = {
    "PlaySoundFile": "Questie Forever build calls PlaySoundFile(fileID, channel); wiki API page",
    "PlayMusic": "Soundtrack port played custom MP3 paths on Forever (forum t/2356559); wiki API page",
    "StopMusic": "Soundtrack uses it; wiki API page",
    "StopSound": "Blizzard forever code calls StopSound(handle, fadeMs) (TalkingHeadUI.lua)",
    "MuteSoundFile": "wiki API page (8.2.0+); unverified on Forever",
    "UnmuteSoundFile": "wiki API page (8.2.0+); unverified on Forever",
    "GetCurrentRegion": "AceDB calls it; returned an unknown region id on the Forever beta",
    "GetCurrentRegionName": "Ace3 MINOR 39 fallback",
    "issecretvalue": "secret helper (Warcraft Wiki Secret_Values)",
    "canaccessvalue": "secret helper",
    "canaccessallvalues": "secret helper",
    "canaccesstable": "secret helper",
    "issecrettable": "secret helper",
    "hasanysecretvalues": "secret helper",
    "scrubsecretvalues": "secret helper",
    "secretwrap": "secret helper",
    "mapvalues": "secret helper",
    "issecure": "taint helper",
    "issecurevariable": "taint helper",
    "securecall": "taint helper",
    "securecallfunction": "taint helper",
    "hooksecurefunc": "taint helper",
    "InCombatLockdown": "combat lockdown query",
    "CreateFrame": "frame factory",
    "GetTime": "time",
    "GetBuildInfo": "build info",
    "GetLocale": "locale",
    "ReloadUI": "reload",
    "import": "Forever 70291+ module import (Warcraft Wiki API:import)",
    "UIParent": "engine-created root frame",
    "WorldFrame": "engine-created world frame",
    "SlashCmdList": "engine/FrameXML slash command table (assign SlashCmdList[KEY])",
    "Enum": "generated enum table (see enum records)",
    "Constants": "generated constants table (see const records)",
}
_SOUNDKIT = re.compile(r"^\s*([A-Z0-9_]+)\s*=\s*(\d+)\s*[,;]?")


def _tokens(s):
    return {x.strip().lower() for x in re.split(r"[,\s]+", s) if x.strip()}


def on_forever(allow, exclude):
    if exclude & {"camelot", "forever"}:
        return False
    if allow and not (allow & FOREVER_TYPES):
        return False
    return True


def scan_tocs(base):
    """Return {addon: {"allow":set,"exclude":set,"files":{relpath_lower:(allow,exclude)}}}."""
    out = {}
    for toc in glob.glob(os.path.join(base, "Interface", "AddOns", "*", "*.toc")):
        addon = os.path.basename(os.path.dirname(toc))
        info = out.setdefault(addon, {"allow": set(), "exclude": set(), "files": {}, "tocs": []})
        info["tocs"].append(os.path.basename(toc))
        for line in open(toc, encoding="utf-8", errors="replace"):
            line = line.strip()
            m = _TOC_DIRECTIVE.match(line)
            if m:
                key, val = m.group(1).lower(), _INLINE.sub("", m.group(2))
                if key == "allowloadgametype":
                    info["allow"] |= _tokens(val)
                elif key == "excludeloadgametype":
                    info["exclude"] |= _tokens(val)
                continue
            if not line or line.startswith("#"):
                continue
            a, e = set(), set()
            for k, v in _INLINE.findall(line):
                (a if k.lower() == "allowloadgametype" else e).update(_tokens(v))
            path = _INLINE.sub("", line)
            path = re.sub(r"\[[^\]]*\]", lambda m: {"[family]": "Mainline", "[game]": "Camelot"}.get(m.group(0).lower(), ""), path).strip()
            info["files"][path.replace("/", "\\").lower()] = (a, e)
    return out


def build_framexml(log=print):
    base = config.UPSTREAM_DIR
    tocs = scan_tocs(base)
    recs = []
    for addon, info in sorted(tocs.items()):
        recs.append({"k": "addon", "id": addon, "forever": on_forever(info["allow"], info["exclude"]),
                     **({"allow": sorted(info["allow"])} if info["allow"] else {}),
                     **({"exclude": sorted(info["exclude"])} if info["exclude"] else {})})
    seen = {}
    lua_files = glob.glob(os.path.join(base, "Interface", "AddOns", "**", "*.lua"), recursive=True)
    # pass 1: top-level global tables, so indented `function Owner.Member(` inside do-blocks can be trusted
    top_tables = set()
    for path in lua_files:
        try:
            for line in open(path, encoding="utf-8", errors="replace"):
                m = re.match(r"^([A-Za-z_]\w*)\s*=\s*(\{|CreateFromMixins|Mixin)", line)
                if m:
                    top_tables.add(m.group(1))
        except OSError:
            pass
    for path in lua_files:
        rel = os.path.relpath(path, os.path.join(base, "Interface", "AddOns"))
        parts = rel.split(os.sep)
        addon = parts[0]
        inner = "\\".join(parts[1:]).lower()
        info = tocs.get(addon, {"allow": set(), "exclude": set(), "files": {}})
        fa, fe = info["files"].get(inner, (set(), set()))
        forever = on_forever(info["allow"], info["exclude"]) and on_forever(fa, fe)
        low = rel.lower()
        if "\\classic\\" in low or "\\standard\\" in low or "\\wowlabs\\" in low:
            forever = forever and inner in info["files"]
        deprecated = "deprecated" in low
        is_soundkit = os.path.basename(path).lower() == "soundkitconstants.lua"
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for line in text.splitlines():
            if is_soundkit:
                m = _SOUNDKIT.match(line)
                if m:
                    recs.append({"k": "soundkit", "id": "SOUNDKIT." + m.group(1), "v": int(m.group(2))})
                    continue
            if not line:
                continue
            line = re.sub(r"^--\[(=*)\[.*?\]\1\]\s*", "", line)  # `--[[static]] function Item:Create...`
            if line[:1].isspace():
                m = _FN_MEMBER.match(line.lstrip())
                if not (m and m.group(1) in top_tables):
                    continue
            name = None
            kind = None
            m = _FN_MEMBER.match(line.lstrip())
            if m:
                name, kind = f"{m.group(1)}.{m.group(2)}", "member"
            else:
                m = _FN_GLOBAL.match(line)
                if m:
                    name, kind = m.group(1), "function"
                else:
                    m = _VAR_MEMBER.match(line)
                    if m:
                        name, kind = f"{m.group(1)}.{m.group(2)}", "member"
                    else:
                        m = _VAR_GLOBAL.match(line)
                        if m and m.group(1) not in ("local", "return", "if", "for", "while", "end"):
                            name, kind = m.group(1), "var"
            if not name:
                continue
            if kind == "member" and _MIXINISH.search(name.split(".")[0]):
                continue  # methods on mixins/templates are reached via instances, not globals
            prev = seen.get(name)
            rec = {"k": "fx", "id": name, "type": kind, "a": addon, "forever": forever}
            if deprecated:
                rec["deprecated"] = True
            if prev is None:
                seen[name] = rec
            elif forever and not prev["forever"]:
                seen[name] = rec  # prefer a definition that loads on Forever
            elif forever and prev.get("deprecated") and not deprecated:
                seen[name] = rec
    # Named, non-virtual XML frames/regions become globals (UIParent, GameTooltip, ChatFrame1, ...)
    xml_rx = re.compile(r"<([A-Za-z]+)\b([^>]*?)\bname\s*=\s*\"([A-Za-z_]\w*)\"([^>]*)>", re.S)
    for path in glob.glob(os.path.join(base, "Interface", "AddOns", "**", "*.xml"), recursive=True):
        rel = os.path.relpath(path, os.path.join(base, "Interface", "AddOns"))
        parts = rel.split(os.sep)
        addon = parts[0]
        info = tocs.get(addon, {"allow": set(), "exclude": set(), "files": {}})
        forever = on_forever(info["allow"], info["exclude"])
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for m in xml_rx.finditer(text):
            attrs = m.group(2) + m.group(4)
            if re.search(r'virtual\s*=\s*"true"', attrs, re.I):
                continue
            name = m.group(3)
            if name in seen and (seen[name]["forever"] or not forever):
                continue
            seen[name] = {"k": "fx", "id": name, "type": "xml-" + m.group(1).lower(), "a": addon, "forever": forever}
    for name, note in UNDOCUMENTED_C.items():
        if name not in seen:
            seen[name] = {"k": "fx", "id": name, "type": "c-global", "a": "(curated)", "note": note, "forever": True}
    for r in seen.values():
        if r["forever"]:
            del r["forever"]
        else:
            r["forever"] = False
        recs.append(r)
    return recs


# ---------------------------------------------------------------- write / load
def _sort_key(r):
    return (r.get("k", ""), r.get("id", ""))


def write_jsonl(path, meta, recs):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps(meta, ensure_ascii=False, separators=(",", ":")) + "\n")
        for r in sorted(recs, key=_sort_key):
            f.write(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n")


def build(cfg, log=print, compare_live=True):
    info = upstream_info()
    live = live_doc_files(cfg) if compare_live else None
    doc_recs, failures, nfiles = build_docs(cfg, live, log)
    if failures:
        for f in failures:
            log("PARSE FAIL " + f)
        if len(failures) > max(1, nfiles // 100):
            raise SystemExit(f"too many doc parse failures ({len(failures)}/{nfiles})")
    fx = build_framexml(log)
    dd = data_dir(cfg["_root"])
    meta = {"k": "meta", "schema": SCHEMA, "branch": cfg["upstream"]["branch"], "commit": info["commit"],
            "build": info["build"], "files": nfiles, "parse_failures": len(failures), "compared_live": live is not None}
    write_jsonl(os.path.join(dd, "api-index.jsonl"), meta, doc_recs)
    write_jsonl(os.path.join(dd, "framexml.jsonl"), {**meta, "layer": "framexml"}, fx)
    return meta, len(doc_recs), len(fx)


class Index:
    """In-memory view over the three layers."""

    def __init__(self, root):
        self.root = root
        dd = data_dir(root)
        self.meta = {}
        self.docs = {}
        self.fx = {}
        self.soundkit = {}
        self.addons = {}
        self.rt = set()
        self.rt_meta = {}
        self._load(os.path.join(dd, "api-index.jsonl"), self._doc)
        self._load(os.path.join(dd, "framexml.jsonl"), self._fxrec)
        self._load(os.path.join(dd, "runtime-surface.jsonl"), self._rtrec)

    def _load(self, path, fn):
        if not os.path.isfile(path):
            return
        with open(path, encoding="utf-8") as f:
            for i, line in enumerate(f):
                r = json.loads(line)
                if r.get("k") == "meta":
                    if fn == self._doc:
                        self.meta = r
                    elif fn == self._rtrec:
                        self.rt_meta = r
                    continue
                fn(r)

    def _doc(self, r):
        key = (r["k"], r["id"])
        self.docs[key] = r

    def _fxrec(self, r):
        if r["k"] == "soundkit":
            self.soundkit[r["id"]] = r["v"]
        elif r["k"] == "addon":
            self.addons[r["id"]] = r
        else:
            self.fx[r["id"]] = r

    def _rtrec(self, r):
        self.rt.add(r["id"])

    @property
    def loaded(self):
        return bool(self.docs)

    def namespaces(self):
        return {i for (k, i) in self.docs if k == "ns"}

    def lookup(self, name):
        """All records matching an exact id (any kind)."""
        out = [r for (k, i), r in self.docs.items() if i == name]
        if name in self.fx:
            out.append(self.fx[name])
        if name in self.soundkit:
            out.append({"k": "soundkit", "id": name, "v": self.soundkit[name]})
        return out

    def known_function(self, name):
        """Evidence that a (dotted) function/value exists. Returns set of layers."""
        src = set()
        if ("fn", name) in self.docs or ("ns", name) in self.docs:
            src.add("doc")
        if name in self.fx:
            src.add("fx")
        if name in self.rt:
            src.add("rt")
        return src

    def known_event(self, name):
        return ("event", name) in self.docs or ("rt-event:" + name) in self.rt

    def find(self, pattern, kinds=None, limit=200):
        rx = re.compile(pattern, re.I)
        out = []
        for (k, i), r in self.docs.items():
            if (kinds is None or k in kinds) and rx.search(i):
                out.append(r)
        if kinds is None or "fx" in kinds:
            for i, r in self.fx.items():
                if rx.search(i):
                    out.append(r)
        if kinds is None or "rt" in kinds:
            for i in self.rt:
                if rx.search(i) and not any(x["id"] == i for x in out):
                    out.append({"k": "rt", "id": i})
        out.sort(key=_sort_key)
        return out[:limit]

    def evidence(self, name):
        src = self.known_function(name)
        parts = []
        if "doc" in src:
            parts.append("documented")
        if "fx" in src:
            parts.append("FrameXML")
        if self.rt_meta:
            parts.append(("present" if "rt" in src else "NOT seen") + f" at runtime (probe {self.rt_meta.get('build', '?')})")
        return ", ".join(parts) or "unknown"


def format_record(r):
    k = r.get("k")
    lines = []
    if k in ("fn", "method"):
        args = ", ".join(_fmt_field(a) for a in r.get("args", []))
        rets = ", ".join(_fmt_field(a) for a in r.get("ret", []))
        lines.append(f"{r['id']}({args})" + (f" -> {rets}" if rets else ""))
        tags = []
        if r.get("secret") and r["secret"] != "never":
            tags.append(f"secret:{r['secret']}")
        for t in ("protected", "restricted", "secure_only", "forever_only"):
            if r.get(t):
                tags.append(t)
        if r.get("crashes"):
            tags.append("CRASHES CLIENT: " + r["crashes"])
        if tags:
            lines.append("  [" + "] [".join(tags) + "]")
        f = r.get("f") or {}
        if f:
            lines.append("  flags: " + ", ".join(f"{a}={b}" for a, b in f.items()))
        if r.get("doc"):
            lines.append("  doc: " + r["doc"])
        lines.append(f"  source: {r.get('file')}")
    elif k == "event":
        pl = ", ".join(_fmt_field(a) for a in r.get("payload", []))
        lines.append(f"EVENT {r['id']}({pl})  [{r.get('sys')}]")
        if r.get("f"):
            lines.append("  flags: " + ", ".join(f"{a}={b}" for a, b in r["f"].items()))
    elif k in ("enum", "const"):
        lines.append(f"{r['id']} = " + json.dumps(r.get("v"), ensure_ascii=False))
    elif k in ("struct", "callback"):
        lines.append(f"{k} {r['id']} {{ " + ", ".join(_fmt_field(a) for a in r.get("fields", [])) + " }")
    elif k == "ns":
        lines.append(f"namespace {r['id']} (system {r.get('sys')}" + (f", env {r['env']}" if r.get("env") else "") + (", forever-only" if r.get("forever_only") else "") + ")")
    elif k == "pred":
        lines.append(f"predicate {r['id']} ({r.get('kind')}, failure {r.get('failure', '-')}): {r.get('doc', '')}")
    elif k == "fx":
        lines.append(f"FrameXML {r['type']} {r['id']}  ({r.get('a')}; {'NOT loaded on Forever' if r.get('forever') is False else 'loads on Forever'}{', deprecated shim' if r.get('deprecated') else ''})")
        if r.get("note"):
            lines.append("  undocumented C global — evidence: " + r["note"])
    elif k == "soundkit":
        lines.append(f"{r['id']} = {r['v']}")
    elif k == "rt":
        lines.append(f"{r['id']}  (runtime only — undocumented)")
    else:
        lines.append(json.dumps(r, ensure_ascii=False))
    return "\n".join(lines)


def _fmt_field(a):
    s = f"{a.get('n')}:{a.get('t')}"
    if a.get("it"):
        s += f"<{a['it']}>"
    if a.get("o"):
        s += "?"
    if "d" in a:
        s += f"={a['d']}"
    if a.get("sec"):
        s += " {" + ",".join(a["sec"]) + "}"
    return s
