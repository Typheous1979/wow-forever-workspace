"""Forever lint.  python tools/wowf/cli.py lint ADDON_DIR [--json] [--no-luacheck] [--no-queries]

Output: path:line:col: SEVERITY [ID] message -> fix
Exit: 0 clean (warnings allowed), 1 errors found, 2 internal failure.
Suppress: `-- wowf-ignore: ID reason` on the same or previous line; `-- wowf-ignore-file: ID` anywhere.
Rule table: see .claude/skills/wowf-review/SKILL.md.
"""
import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, asdict

import config
import index as idx
import luacheckrc
from lua_lexer import tokenize, LuaSyntaxError
from toc import addon_tocs, forever_toc, SUFFIXES

SEV_ORDER = {"E": 0, "W": 1, "I": 2}
CLEU = {"COMBAT_LOG_EVENT_UNFILTERED", "COMBAT_LOG_EVENT"}
SILENT_FAIL = {
    "ChatFrame_OpenChat": "protected on Forever: fails silently (no Lua error). Let the client open chat; use HandleModifiedItemClick for shift-click links",
    "ChatEdit_ActivateChat": "protected on Forever: fails silently",
    "SetRaidTarget": "addons cannot set raid target markers on Forever",
    "C_SuperTrack.SetSuperTrackedUserWaypoint": "protected on Forever: fails silently; use C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(...))",
}
OLD_OPTIONS = {"InterfaceOptions_AddCategory", "InterfaceOptionsFrame_OpenToCategory", "InterfaceOptionsFrame_AddCategory",
               "InterfaceAddOnsList_Update", "InterfaceOptionsFramePanelContainer"}
_DIRECTIVE_NAMES = {"addoncompartmentfunc": "AddonCompartmentFunc", "addoncompartmentfunconenter": "AddonCompartmentFuncOnEnter", "addoncompartmentfunconleave": "AddonCompartmentFuncOnLeave"}
SOUND_PATH_FUNCS = {"PlaySoundFile", "PlayMusic", "MuteSoundFile", "UnmuteSoundFile"}
OS_ALLOWED = {"time", "date", "clock", "difftime"}
EVENT_REG = {"RegisterEvent", "RegisterUnitEvent", "UnregisterEvent", "RegisterEventCallback", "RegisterFrameEventAndCallback", "IsEventRegistered"}
ARITH_CMP = {"+", "-", "*", "/", "%", "^", "..", "<", ">", "<=", ">=", "==", "~="}
LIB_DIRS = ("libs", "lib", "tests", "locales", "locale", ".git")


@dataclass
class Finding:
    path: str
    line: int
    col: int
    sev: str
    id: str
    msg: str
    fix: str = ""

    def text(self, root):
        rel = _rel(self.path, root) if self.path else "?"
        s = f"{rel}:{self.line}:{self.col}: {self.sev} [{self.id}] {self.msg}"
        return s + (f" -> {self.fix}" if self.fix else "")


def _rel(path, root):
    try:
        return os.path.relpath(path, root)
    except ValueError:  # different drive
        return path


def _load_removed():
    with open(os.path.join(os.path.dirname(__file__), "data", "removed_apis.json"), encoding="utf-8") as f:
        d = json.load(f)
    d.pop("_comment", None)
    return d


class AddonLinter:
    def __init__(self, addon_dir, cfg, I, removed):
        self.dir = os.path.abspath(addon_dir)
        self.folder = os.path.basename(os.path.normpath(self.dir))
        self.cfg = cfg
        self.I = I
        self.removed = removed
        self.findings = []
        self.queries = {"functions": set(), "events": set()}
        self.ignores = {}       # path -> {line: set(ids)}
        self.file_ignores = {}  # path -> set(ids)
        self.all_tokens = {}    # path -> tokens
        self.lsvf = False
        self.sv_names = []

    def add(self, path, line, col, sev, rid, msg, fix=""):
        self.findings.append(Finding(path, line, col, sev, rid, msg, fix))

    # ------------------------------------------------------------ TOC
    def check_tocs(self):
        folder, tocs = addon_tocs(self.dir)
        if not tocs:
            self.add(self.dir, 1, 1, "E", "TOC001", f"no .toc file in {folder}", f"create {folder}.toc")
            return None
        names_ok = [t for t in tocs if t.name == folder or any(t.name == folder + s for s in SUFFIXES)]
        for t in tocs:
            if t not in names_ok:
                self.add(t.path, 1, 1, "E", "TOC001", f"TOC name '{t.name}' does not match folder '{folder}' (case-sensitive)", f"rename to {folder}.toc or {folder}_Camelot.toc")
            if t.has_bom:
                self.add(t.path, 1, 1, "E", "TOC007", "TOC starts with a UTF-8 BOM", "save without BOM (use the Write tool, not PowerShell Out-File)")
        ft = forever_toc(self.dir)
        if ft is None:
            self.add(self.dir, 1, 1, "E", "TOC002", "no TOC that the Forever client will load", f"add {folder}.toc or {folder}_Camelot.toc with ## Interface: 16001")
            return None
        want = set(self.cfg.get("forever_interfaces", [16001]))
        ifaces = ft.interfaces()
        if not want & set(ifaces):
            line = ft.directive_lines.get("interface", 1)
            self.add(ft.path, line, 1, "E", "TOC002", f"Interface {ifaces or '(missing)'} does not include {sorted(want)} — Forever flags the addon out of date",
                     "## Interface: 16001 (or add 16001 to a comma-separated list)")
        self.lsvf = ft.get("loadsavedvariablesfirst", "0").strip() == "1"
        self.sv_names = ft.saved_variables()
        tokens = set(self.cfg.get("game_type_tokens", []))
        for t in tocs:
            for key in ("allowloadgametype", "excludeloadgametype"):
                for tok in re.split(r"[,\s]+", t.get(key, "") or ""):
                    if tok and tok.lower() not in tokens:
                        self.add(t.path, t.directive_lines.get(key, 1), 1, "W", "TOC006", f"unknown game type '{tok}' — unrecognized types still LOAD the file/addon", "check spelling; pair with ExcludeLoadGameType")
            for n, path, inline in t.files:
                for key in ("allowloadgametype", "excludeloadgametype"):
                    for tok in re.split(r"[,\s]+", inline.get(key, "") or ""):
                        if tok and tok.lower() not in tokens:
                            self.add(t.path, n, 1, "W", "TOC006", f"unknown game type '{tok}'", "known: " + ", ".join(sorted(tokens)))
        # listed files exist
        listed = set()
        for t in tocs:
            for n, rel, inline in t.files:
                full = os.path.join(self.dir, rel)
                listed.add(os.path.normcase(os.path.normpath(full)))
                if not os.path.exists(full):
                    self.add(t.path, n, 1, "E", "TOC003", f"listed file '{rel}' does not exist", "fix the path (backslashes, case) or remove the line")
                else:
                    actual = self._actual_case(full)
                    if actual and os.path.basename(actual) != os.path.basename(full):
                        self.add(t.path, n, 1, "W", "TOC003", f"case mismatch: '{rel}' vs '{os.path.basename(actual)}'", "match the file name exactly")
                    if full.lower().endswith(".xml"):
                        listed |= self._xml_includes(full)
        # unlisted lua/xml
        for dirpath, dirnames, files in os.walk(self.dir):
            dirnames[:] = [d for d in dirnames if d.lower() not in LIB_DIRS]
            for f in files:
                if f.lower().endswith((".lua", ".xml")):
                    if f.lower() == "bindings.xml" and os.path.samefile(dirpath, self.dir):
                        continue  # the client loads <Addon>\Bindings.xml itself; it must not be in the TOC
                    full = os.path.normcase(os.path.normpath(os.path.join(dirpath, f)))
                    if full not in listed:
                        extra = " (OneDrive conflict copy?)" if re.search(r"-[A-Z0-9-]{3,}\.(lua|xml)$", f) else ""
                        self.add(os.path.join(dirpath, f), 1, 1, "W", "TOC004", f"{f} is not listed in the TOC — it will not load{extra}", "add it to the TOC or delete it")
        return ft

    def _actual_case(self, full):
        d, b = os.path.split(full)
        try:
            for f in os.listdir(d):
                if f.lower() == b.lower():
                    return os.path.join(d, f)
        except OSError:
            return None
        return None

    def _xml_includes(self, xml):
        out = set()
        try:
            text = open(xml, encoding="utf-8", errors="replace").read()
        except OSError:
            return out
        for m in re.finditer(r'<(?:Script|Include)\s+[^>]*file\s*=\s*"([^"]+)"', text, re.I):
            p = os.path.normcase(os.path.normpath(os.path.join(os.path.dirname(xml), m.group(1).replace("/", "\\"))))
            out.add(p)
            if p.endswith(".xml") and os.path.isfile(p):
                out |= self._xml_includes(p)
        return out

    def check_compartment(self, ft, lua_texts):
        for key, fn in ft.compartment_funcs().items():
            pat = re.compile(r"(^|\n)\s*(function\s+%s\s*\(|%s\s*=\s*function\b)|_G\s*(\.%s\b|\[\s*[\"']%s[\"']\s*\])" % ((re.escape(fn),) * 4))
            if not any(pat.search(t) for t in lua_texts.values()):
                self.add(ft.path, ft.directive_lines.get(key, 1), 1, "E", "TOC005",
                         f"{_DIRECTIVE_NAMES.get(key, key)} names global '{fn}' but no Lua file defines it (case-sensitive)", f"define `function {fn}(addonName, buttonName)` as a global")

    # ------------------------------------------------------------ Lua
    def lua_files(self):
        out = []
        for dirpath, dirnames, files in os.walk(self.dir):
            dirnames[:] = [d for d in dirnames if d.lower() not in ("libs", "lib", "tests", ".git")]
            for f in files:
                if f.lower().endswith(".lua"):
                    out.append(os.path.join(dirpath, f))
        return sorted(out)

    def check_lua(self, path, data, all_slash, addon_has_camelot):
        try:
            toks, lx = tokenize(data)
        except LuaSyntaxError as e:
            self.add(path, e.line, e.col, "E", "LUA000", f"syntax error: {e.msg}")
            return
        self.all_tokens[path] = toks
        rel_low = os.path.relpath(path, self.dir).lower()
        # ignore directives
        ign = {}
        for line, text in lx.comments:
            m = re.search(r"wowf-ignore-file:\s*([A-Z]+\d+(?:\s*,\s*[A-Z]+\d+)*)", text)
            if m:
                self.file_ignores.setdefault(path, set()).update(x.strip() for x in m.group(1).split(","))
            m = re.search(r"wowf-ignore:\s*([A-Z]+\d+(?:\s*,\s*[A-Z]+\d+)*)", text)
            if m:
                ids = {x.strip() for x in m.group(1).split(",")}
                ign.setdefault(line, set()).update(ids)
                ign.setdefault(line + 1, set()).update(ids)
        self.ignores[path] = ign
        if lx.has_bom:
            self.add(path, 1, 1, "W", "TOC007", "Lua file starts with a UTF-8 BOM", "save without BOM")
        for line, col, msg in lx.notes:
            self.add(path, line, col, "W", "LUA005", msg, "use \\ddd decimal escapes")

        n = len(toks)
        locals_ = self._local_names(toks)
        # PAT004 header
        if not rel_low.startswith(("locales", "locale")):
            sig = [t for t in toks[:8]]
            ok = (len(sig) >= 6 and sig[0].is_kw("local") and sig[1].kind == "name" and sig[2].is_op(",")
                  and sig[3].kind == "name" and sig[4].is_op("=") and sig[5].is_op("..."))
            if not ok:
                self.add(path, toks[0].line if toks else 1, 1, "W", "PAT004", "file does not start with `local addonName, ns = ...`", "begin every addon Lua file with: local addonName, ns = ...")

        stack = []
        func_depth = 0
        for i, t in enumerate(toks):
            # block tracking for PAT001
            if t.kind == "keyword":
                if t.value == "function":
                    stack.append("f"); func_depth += 1
                elif t.value in ("do", "if", "repeat"):
                    if t.value == "do" and stack and stack[-1] == "loop":
                        stack[-1] = "b"
                    else:
                        stack.append("b")
                elif t.value in ("while", "for"):
                    stack.append("loop")
                elif t.value in ("end", "until"):
                    if stack:
                        if stack.pop() == "f":
                            func_depth -= 1
            prev = toks[i - 1] if i else None
            nxt = toks[i + 1] if i + 1 < n else None
            # 5.2+ syntax
            if t.kind == "op":
                if t.value == "//":
                    self.add(path, t.line, t.col, "E", "LUA002", "`//` (integer division) is Lua 5.3+", "use math.floor(a / b)")
                elif t.value in ("&", "|", "~", "<<", ">>"):
                    self.add(path, t.line, t.col, "E", "LUA003", f"bitwise operator `{t.value}` is Lua 5.3+", "use bit.band/bit.bor/bit.bxor/bit.lshift/bit.rshift")
                elif t.value == "::":
                    self.add(path, t.line, t.col, "E", "LUA001", "labels `::name::` are Lua 5.2+", "restructure with loops/flags (no goto in 5.1)")
                continue
            if t.kind == "name" and t.value == "goto" and nxt is not None and nxt.kind == "name" and not (prev and prev.is_op(".", ":")):
                self.add(path, t.line, t.col, "E", "LUA001", "`goto` is Lua 5.2+", "restructure with loops/flags")
                continue
            if t.kind == "name" and t.value == "_ENV":
                self.add(path, t.line, t.col, "E", "LUA004", "_ENV is Lua 5.2+", "use the addon namespace table")
                continue
            if t.kind == "string" and t.value in CLEU:
                self.add(path, t.line, t.col, "E", "API003", f"{t.value} is unavailable to addons on Forever (registering it errors)", "drop the combat-log feature; use unit events or Blizzard's built-in damage meter/cooldown manager")
                continue
            if t.kind != "name" or (prev is not None and prev.is_op(".", ":")):
                continue
            # global chain head
            chain, j = [t.value], i
            while j + 2 < n and toks[j + 1].is_op(".") and toks[j + 2].kind == "name":
                chain.append(toks[j + 2].value)
                j += 2
            after = toks[j + 1] if j + 1 < n else None
            head = chain[0]
            dotted = ".".join(chain[:2])
            is_local = head in locals_
            is_decl = prev is not None and (prev.is_kw("local", "function") or prev.is_op(","))  # rough
            if is_local:
                continue
            is_call = after is not None and (after.is_op("(") or after.kind == "string" or after.is_op("{"))
            assigned = after is not None and after.is_op("=") and not (prev and prev.is_kw("local"))

            # SV at file scope
            if head in self.sv_names and func_depth == 0 and not self.lsvf:
                self.add(path, t.line, t.col, "E", "PAT001", f"SavedVariable {head} touched at file scope — it is nil/overwritten until ADDON_LOADED",
                         "read/initialise it inside your ADDON_LOADED handler (or add ## LoadSavedVariablesFirst: 1)")
            # API001 banned libs
            if head in ("require", "dofile", "loadfile", "module") and is_call:
                self.add(path, t.line, t.col, "E", "API001", f"{head}() does not exist in WoW's Lua", "list files in the TOC; share state on the addon namespace")
            elif head in ("io", "package"):
                self.add(path, t.line, t.col, "E", "API001", f"the `{head}` library does not exist in WoW", "")
            elif head == "os" and len(chain) > 1 and chain[1] not in OS_ALLOWED:
                self.add(path, t.line, t.col, "E", "API001", f"os.{chain[1]} does not exist (WoW keeps only os.time/date/clock/difftime)", "")
            # API002 removed globals
            if len(chain) == 1 and head in self.removed and not assigned and not self._defines(toks, head):
                fxr = self.I.fx.get(head)
                rec = self.I.lookup(head)
                if fxr and fxr.get("forever") is not False and fxr.get("deprecated"):
                    self.add(path, t.line, t.col, "W", "API002", f"{head} only exists as a deprecated shim", "use " + self.removed[head]["use"])
                elif any(r.get("k") == "fn" for r in rec) or head in self.I.rt:
                    self.add(path, t.line, t.col, "W", "API002", f"{head} is on the removed list but the index says it exists — verify with wowf-api", "prefer " + self.removed[head]["use"])
                else:
                    self.add(path, t.line, t.col, "E", "API002", f"{head} does not exist on Forever", "use " + self.removed[head]["use"])
            if head.startswith("CombatLog") and is_call:
                self.add(path, t.line, t.col, "E", "API003", f"{head} — the combat log is unavailable to addons on Forever", "drop the feature")
            if head in OLD_OPTIONS:
                self.add(path, t.line, t.col, "E", "API005", f"{head} is the removed pre-10.0 options API", "Settings.RegisterVerticalLayoutCategory + Settings.RegisterAddOnCategory; open with Settings.OpenToCategory(category:GetID())")
            # silent-fail calls
            key = dotted if dotted in SILENT_FAIL else head if head in SILENT_FAIL else None
            if key:
                self.add(path, t.line, t.col, "E", "SEC002", f"{key}: {SILENT_FAIL[key]}", "")
            # sound paths
            if head in SOUND_PATH_FUNCS and len(chain) == 1 and after is not None and after.is_op("(") and j + 2 < n and toks[j + 2].kind == "string":
                arg = toks[j + 2].value.replace("/", "\\").lower()
                if not arg.startswith("interface\\addons\\"):
                    self.add(path, t.line, t.col, "E", "API006", f"{head} with internal path '{toks[j + 2].value}' — game file paths stopped working in 8.2.0 and fail silently",
                             "pass a FileDataID (number), a SOUNDKIT id via PlaySound, or a path under Interface\\AddOns\\YourAddon\\")
            if head == "PlaySound" and after is not None and after.is_op("(") and j + 2 < n and toks[j + 2].kind == "string":
                self.add(path, t.line, t.col, "E", "API006", "PlaySound takes a SoundKitID number, not a string", "PlaySound(SOUNDKIT.IG_MAINMENU_OPEN)")
            # API007 existence (C_ namespaces)
            if head.startswith("C_") and not assigned:
                self._check_c_api(path, t, chain)
            # events
            if head in EVENT_REG or (len(chain) == 1 and False):
                pass
            # PAT002: result of a no-return function used
            if len(chain) == 2 and is_call:
                recs = [r for r in self.I.lookup(dotted) if r.get("k") == "fn"]
                if recs and not recs[0].get("ret") and prev is not None and (prev.is_op("=", ",") or prev.is_kw("return")):
                    self.add(path, t.line, t.col, "E", "PAT002", f"{dotted} returns nothing — the value is always nil",
                             "C_Timer.NewTimer/NewTicker return a cancellable handle" if dotted == "C_Timer.After" else "")
                if recs and recs[0].get("protected"):
                    self.add(path, t.line, t.col, "W", "SEC003", f"{dotted} is a protected function", "blocked in combat lockdown / from insecure code")
                if recs and recs[0].get("secure_only"):
                    self.add(path, t.line, t.col, "E", "API004", f"{dotted} is SecureOnly — addons cannot call it", "")
                elif recs and recs[0].get("restricted"):
                    self.add(path, t.line, t.col, "I", "API004", f"{dotted} has restrictions (may do nothing in combat/instances/lockdown)", "check the doc flags with wowf-api")
            # SEC001 secret math
            if is_call and len(chain) <= 2:
                self._check_secret_use(path, toks, i, j, ".".join(chain))
        # method-style event registration: frame:RegisterEvent("X")
        for i, t in enumerate(toks):
            if t.kind == "name" and t.value in EVENT_REG and i + 2 < n and toks[i + 1].is_op("(") and toks[i + 2].kind == "string":
                ev = toks[i + 2].value
                if ev in CLEU:
                    continue
                if self.I.loaded and not self.I.known_event(ev) and re.fullmatch(r"[A-Z0-9_]+", ev):
                    self.add(path, toks[i + 2].line, toks[i + 2].col, "E", "API007", f"unknown event '{ev}' (not in Blizzard's Forever docs)", "check spelling with `wowf-api events`; queued for WowfProbe")
                    self.queries["events"].add(ev)
        # PAT003 project id
        for i, t in enumerate(toks):
            if t.kind == "name" and t.value == "WOW_PROJECT_ID" and i + 2 < n and toks[i + 1].is_op("==", "~=") and not addon_has_camelot:
                o = toks[i + 2]
                if (o.kind == "name" and o.value in ("WOW_PROJECT_MAINLINE", "WOW_PROJECT_CLASSIC")) or o.kind == "number":
                    self.add(path, t.line, t.col, "W", "PAT003", "WOW_PROJECT_ID branch without WOW_PROJECT_CAMELOT — Forever is 18 (WOW_PROJECT_CAMELOT) since 70170 and falls into the wrong branch",
                             "local isForever = WOW_PROJECT_CAMELOT ~= nil and WOW_PROJECT_ID == WOW_PROJECT_CAMELOT")
        # slash commands collected for PAT005
        for i, t in enumerate(toks):
            if t.kind == "name" and (i == 0 or not toks[i - 1].is_op(".", ":")):
                m = re.fullmatch(r"SLASH_([A-Za-z0-9_]+?)(\d+)", t.value)
                if m and i + 1 < n and toks[i + 1].is_op("="):
                    val = toks[i + 2].value if i + 2 < n and toks[i + 2].kind == "string" else None
                    all_slash["slash"].append((path, t.line, t.col, m.group(1), int(m.group(2)), val))
                if t.value == "SlashCmdList" and i + 3 < n:
                    if toks[i + 1].is_op(".") and toks[i + 2].kind == "name" and toks[i + 3].is_op("="):
                        all_slash["keys"].append((path, t.line, t.col, toks[i + 2].value))
                    elif toks[i + 1].is_op("[") and toks[i + 2].kind == "string" and i + 4 < n and toks[i + 3].is_op("]") and toks[i + 4].is_op("="):
                        all_slash["keys"].append((path, t.line, t.col, toks[i + 2].value))
            if t.is_kw("function") and i + 3 < n and toks[i + 1].kind == "name" and toks[i + 1].value == "SlashCmdList" and toks[i + 2].is_op(".") and toks[i + 3].kind == "name":
                all_slash["keys"].append((path, t.line, t.col, toks[i + 3].value))

    def _defines(self, toks, name):
        for i, t in enumerate(toks):
            if t.kind == "name" and t.value == name:
                prev = toks[i - 1] if i else None
                nxt = toks[i + 1] if i + 1 < len(toks) else None
                if (prev is not None and prev.is_kw("function")) or (nxt is not None and nxt.is_op("=") and not (prev and prev.is_op(".", ":"))):
                    return True
        return False

    def _local_names(self, toks):
        names = set()
        n = len(toks)
        for i, t in enumerate(toks):
            if t.is_kw("local"):
                j = i + 1
                if j < n and toks[j].is_kw("function"):
                    j += 1
                    if j < n and toks[j].kind == "name":
                        names.add(toks[j].value)
                    continue
                while j < n and toks[j].kind == "name":
                    names.add(toks[j].value)
                    if j + 1 < n and toks[j + 1].is_op(","):
                        j += 2
                    else:
                        break
            elif t.is_kw("function"):
                j = i + 1
                while j < n and not toks[j].is_op("("):
                    j += 1
                j += 1
                while j < n and not toks[j].is_op(")"):
                    if toks[j].kind == "name":
                        names.add(toks[j].value)
                    j += 1
            elif t.is_kw("for"):
                j = i + 1
                while j < n and not (toks[j].is_kw("in") or toks[j].is_op("=")):
                    if toks[j].kind == "name":
                        names.add(toks[j].value)
                    j += 1
        return names

    def _check_c_api(self, path, t, chain):
        I = self.I
        if not I.loaded:
            return
        ns = chain[0]
        ns_known = ("ns", ns) in I.docs or ns in I.rt or any(k.startswith(ns + ".") for k in (ns,)) or ns in I.fx
        if not ns_known and not any(i.startswith(ns + ".") for i in I.fx):
            self.add(path, t.line, t.col, "E", "API007", f"unknown namespace {ns} (not documented, not in FrameXML, not seen at runtime)", "do not invent C_ APIs — search with `wowf-api find`")
            self.queries["functions"].add(ns)
            return
        if len(chain) < 2:
            return
        name = f"{ns}.{chain[1]}"
        src = I.known_function(name)
        if name in idx.CRASHES:
            self.add(path, t.line, t.col, "E", "API007", f"{name} is known to CRASH the client (access violation; pcall cannot catch it)", "do not call it")
        elif not src:
            self.add(path, t.line, t.col, "E", "API007", f"unknown function {name} (not in Forever docs/FrameXML/runtime)", "check `wowf-api find`; queued for WowfProbe")
            self.queries["functions"].add(name)
        elif I.rt_meta and "rt" not in src and "doc" in src and I.rt_meta.get("mode", "").startswith(("quick", "full")):
            self.add(path, t.line, t.col, "W", "API007", f"{name} is documented but was NOT present at runtime (probe {I.rt_meta.get('build')})", "guard with a type() check or avoid")

    def _check_secret_use(self, path, toks, i, j, name):
        recs = [r for r in self.I.lookup(name) if r.get("k") == "fn"]
        if not recs or recs[0].get("secret") not in ("always", "conditional"):
            return
        cls = recs[0]["secret"]
        n = len(toks)
        # find closing paren of the call
        k = j + 1
        if k >= n or not toks[k].is_op("("):
            return
        depth = 0
        while k < n:
            if toks[k].is_op("("):
                depth += 1
            elif toks[k].is_op(")"):
                depth -= 1
                if depth == 0:
                    break
            k += 1
        after = toks[k + 1] if k + 1 < n else None
        before = toks[i - 1] if i else None
        before2 = toks[i - 2] if i >= 2 else None
        direct = (after is not None and after.kind == "op" and after.value in ARITH_CMP) or \
                 (before is not None and before.kind == "op" and before.value in ARITH_CMP and before.value != "=") or \
                 (before is not None and before.is_op("(") and before2 is not None and before2.kind == "name" and before2.value in ("tostring", "tonumber", "print", "format"))
        if direct:
            sev = "W" if cls == "always" else "I"
            self.add(path, toks[i].line, toks[i].col, sev, "SEC001",
                     f"{name} returns a {'secret' if cls == 'always' else 'possibly secret'} value — math/compare/concat/tostring on it errors",
                     "feed it to a widget (StatusBar:SetMinMaxValues/SetValue, FontString:SetText) or guard with issecretvalue()")
            return
        # local x = F(...) then x used in arithmetic within the next 25 tokens-lines
        if before is not None and before.is_op("=") and before2 is not None and before2.kind == "name":
            var = before2.value
            guard_lines = set()
            for m in range(k + 1, min(n, k + 400)):
                tm = toks[m]
                if tm.kind == "name" and tm.value in ("issecretvalue", "canaccessvalue", "scrubsecretvalues"):
                    guard_lines.add(tm.line)
                if tm.kind == "name" and tm.value == var:
                    if any(abs(tm.line - g) <= 5 for g in guard_lines):
                        continue
                    nb = toks[m + 1] if m + 1 < n else None
                    pb = toks[m - 1]
                    if (nb is not None and nb.kind == "op" and nb.value in ARITH_CMP) or (pb.kind == "op" and pb.value in ARITH_CMP and pb.value != "="):
                        sev = "W" if cls == "always" else "I"
                        self.add(path, tm.line, tm.col, sev, "SEC001",
                                 f"`{var}` holds {name}() ({'secret' if cls == 'always' else 'possibly secret'}) and is used in math/compare/concat",
                                 "guard with issecretvalue() or pass it straight to a StatusBar/FontString")
                        return

    def check_slash(self, all_slash):
        keys = {k for _, _, _, k in all_slash["keys"]}
        groups = {}
        for path, line, col, key, num, val in all_slash["slash"]:
            groups.setdefault(key, []).append((path, line, col, num, val))
            if val is not None and not val.startswith("/"):
                self.add(path, line, col, "E", "PAT005", f"SLASH_{key}{num} = '{val}' must start with '/'", f"\"/{val}\"")
        for key, items in groups.items():
            if key not in keys:
                p, l, c, _, _ = items[0]
                self.add(p, l, c, "E", "PAT005", f"SLASH_{key}1 has no matching SlashCmdList[\"{key}\"] handler (keys must match exactly)", f'SlashCmdList["{key}"] = function(msg) ... end')
            nums = sorted(x[3] for x in items)
            if nums != list(range(1, len(nums) + 1)):
                p, l, c, _, _ = items[0]
                self.add(p, l, c, "E", "PAT005", f"SLASH_{key} aliases must be numbered 1..n, got {nums}", "")
        for path, line, col, key in all_slash["keys"]:
            if key not in groups:
                self.add(path, line, col, "E", "PAT005", f"SlashCmdList[\"{key}\"] has no SLASH_{key}1 global", f'SLASH_{key}1 = "/{key.lower()}"')

    # ------------------------------------------------------------ luacheck
    def run_luacheck(self, root):
        exe = os.path.join(root, "tools", "luacheck.exe")
        if not os.path.isfile(exe):
            self.add("", 0, 0, "I", "LC000", "luacheck.exe not installed — skipped", "python tools/wowf/setup_luacheck.py")
            return
        inside = os.path.normcase(self.dir).startswith(os.path.normcase(root) + os.sep)
        run_cwd = root if inside else os.path.dirname(self.dir)
        rel_dir = os.path.relpath(self.dir, run_cwd).replace("\\", "/")
        extra = []
        if not any(os.path.normcase(rel_dir + "/") == os.path.normcase(r) for r, _ in luacheckrc.workspace_addons(root)):
            extra = [(rel_dir + "/", self.dir)]
        cfgpath = os.path.join(root, ".luacheckrc")
        content = luacheckrc.generate(root, self.I, extra)
        if not os.path.isfile(cfgpath) or open(cfgpath, encoding="utf-8").read() != content:
            with open(cfgpath, "w", encoding="utf-8", newline="\n") as f:
                f.write(content)
        files = [os.path.relpath(p, run_cwd) for p in self.lua_files()]
        if not files:
            return
        r = subprocess.run([exe, "--config", cfgpath, "--formatter", "plain", "--codes", "--ranges", "--no-color", *files],
                           cwd=run_cwd, capture_output=True, text=True, encoding="utf-8", errors="replace")
        if r.returncode >= 3:
            self.add("", 0, 0, "W", "LC000", f"luacheck failed: {(r.stderr or r.stdout).strip()[:300]}", "")
            return
        strings = self._runtime_strings()
        for line in r.stdout.splitlines():
            m = re.match(r"^(.*?):(\d+):(\d+)(?:-\d+)?: \(([EW])(\d+)\) (.*)$", line)
            if not m:
                continue
            path, ln, col, kind, code, msg = m.group(1), int(m.group(2)), int(m.group(3)), m.group(4), m.group(5), m.group(6)
            full = os.path.join(run_cwd, path)
            rid = f"LC{kind}{code}"
            sev = "W"
            if kind == "E" or code in ("111", "121", "143"):
                sev = "E"
            elif code == "113":
                name = re.search(r"'([^']+)'", msg)
                nm = name.group(1) if name else ""
                if nm in strings:
                    continue
                sev = "E" if not re.fullmatch(r"[A-Z0-9_]+", nm) or self.I.rt_meta else "W"
            fix = ""
            if code == "113":
                fix = "misspelled or nonexistent global? check with `wowf-api show`; if it is a Blizzard string constant, run the full probe"
            elif code == "111":
                fix = "make it local, or put it on the addon namespace (ns); only SavedVariables/SLASH_/compartment funcs should be globals"
            elif code == "143":
                fix = "unknown member — invented API? check with `wowf-api find`"
            elif code == "121":
                fix = "never overwrite a Blizzard global (taint)"
            self.add(full, ln, col, sev, rid, msg, fix)

    def _runtime_strings(self):
        p = os.path.join(config.RUNTIME_DIR)
        out = set()
        if not os.path.isdir(p) or not self.I.rt_meta:
            return out
        f = os.path.join(p, f"{self.I.rt_meta.get('build')}.json")
        if os.path.isfile(f):
            try:
                data = json.load(open(f, encoding="utf-8"))
                out = set((data.get("full") or {}).get("string", "").split("\n"))
            except (OSError, ValueError):
                pass
        return out

    # ------------------------------------------------------------ run
    def run(self, root, use_luacheck=True):
        ft = self.check_tocs()
        files = self.lua_files()
        texts = {}
        for p in files:
            with open(p, "rb") as fh:
                texts[p] = fh.read()
        decoded = {p: d.decode("utf-8", "replace") for p, d in texts.items()}
        camelot = any("WOW_PROJECT_CAMELOT" in d for d in decoded.values())
        if ft is not None:
            self.check_compartment(ft, decoded)
        all_slash = {"slash": [], "keys": []}
        for p in files:
            self.check_lua(p, texts[p], all_slash, camelot)
        self.check_slash(all_slash)
        if use_luacheck:
            self.run_luacheck(root)
        # apply suppressions
        out = []
        suppressed = 0
        for f in self.findings:
            ids = self.ignores.get(f.path, {}).get(f.line, set()) | self.file_ignores.get(f.path, set())
            if f.id in ids:
                suppressed += 1
                continue
            out.append(f)
        out.sort(key=lambda f: (f.path, f.line, f.col, SEV_ORDER[f.sev]))
        # de-duplicate identical findings
        seen, uniq = set(), []
        for f in out:
            k = (f.path, f.line, f.id, f.msg)
            if k not in seen:
                seen.add(k)
                uniq.append(f)
        return uniq, suppressed


def write_queries(root, queries):
    if not (queries["functions"] or queries["events"]):
        return None
    path = os.path.join(root, ".claude", "skills", "wowf-debug", "assets", "WowfProbe", "Queries.lua")
    existing = {"functions": set(), "events": set(), "addons": set()}
    if os.path.isfile(path):
        text = open(path, encoding="utf-8").read()
        for key in existing:
            m = re.search(key + r"\s*=\s*\{([^}]*)\}", text)
            if m:
                existing[key] = set(re.findall(r'"([^"]+)"', m.group(1)))
    for key in ("functions", "events"):
        existing[key] |= set(queries[key])
    def lst(s):
        return ", ".join(f'"{x}"' for x in sorted(s)[:200])
    body = ("local addonName, ns = ...\n"
            "-- Generated by `python tools/wowf/cli.py lint` (names it could not confirm).\n"
            "-- WowfProbe checks each with type()/IsEventValid/GetAddOnInfo and never calls functions.\n"
            "ns.queries = {\n"
            f"    functions = {{ {lst(existing['functions'])} }},\n"
            f"    events = {{ {lst(existing['events'])} }},\n"
            f"    addons = {{ {lst(existing['addons'])} }},\n"
            "}\n")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(body)
    return path


def lint_dir(addon_dir, cfg=None, I=None, use_luacheck=True):
    cfg = cfg or config.load()
    I = I or idx.Index(cfg["_root"])
    linter = AddonLinter(addon_dir, cfg, I, _load_removed())
    findings, suppressed = linter.run(cfg["_root"], use_luacheck)
    return findings, suppressed, linter


def main(argv):
    p = argparse.ArgumentParser(prog="wowf lint")
    p.add_argument("addon", help="addon folder (path or name under the workspace)")
    p.add_argument("--json", action="store_true")
    p.add_argument("--no-luacheck", action="store_true")
    p.add_argument("--no-queries", action="store_true", help="do not queue unknown names for WowfProbe")
    p.add_argument("--min", choices=["E", "W", "I"], default="I", help="minimum severity to print")
    a = p.parse_args(argv)
    cfg = config.load()
    root = cfg["_root"]
    target = a.addon if os.path.isdir(a.addon) else os.path.join(root, a.addon)
    if not os.path.isdir(target):
        print(f"lint: no folder {a.addon}")
        return 2
    try:
        findings, suppressed, linter = lint_dir(target, cfg, use_luacheck=not a.no_luacheck)
    except Exception as e:  # internal failure
        print(f"lint: internal error: {e!r}")
        return 2
    shown = [f for f in findings if SEV_ORDER[f.sev] <= SEV_ORDER[a.min]]
    if a.json:
        print(json.dumps({"addon": target, "findings": [asdict(f) | {"path": _rel(f.path, root) if f.path else ""} for f in shown],
                          "suppressed": suppressed}, indent=1))
    else:
        for f in shown:
            print(f.text(root))
        counts = {s: sum(1 for f in findings if f.sev == s) for s in "EWI"}
        print(f"-- {counts['E']} error(s), {counts['W']} warning(s), {counts['I']} note(s), {suppressed} suppressed  "
              f"[index {linter.I.meta.get('build')}, runtime {linter.I.rt_meta.get('build', 'none')}]")
    if not a.no_queries:
        q = write_queries(root, linter.queries)
        if q and not a.json:
            print(f"queued {len(linter.queries['functions']) + len(linter.queries['events'])} unknown name(s) for WowfProbe: {os.path.relpath(q, root)}")
    return 1 if any(f.sev == "E" for f in findings) else 0
