"""Generate <repo>/.luacheckrc from the API index (docs + FrameXML + runtime) and workspace TOCs.

Not `std = "lua51"`: that would define io/os/require/dofile/loadfile/debug and hide
real Forever problems. Instead two custom stds:
  wowlua  — Lua 5.1 base functions WoW keeps, libraries with their known fields, WoW aliases
  wowapi  — documented globals, C_ namespaces with STRICT fields (invented members -> W143),
            Enum/Constants with fields, FrameXML globals (read-only, so overwriting -> W121)
Per-addon globals (SavedVariables, SLASH_*, BINDING_*, compartment functions) go in files[...].
"""
import os
import re

from toc import addon_tocs

IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

LUA_BASE = ["assert", "error", "getmetatable", "setmetatable", "ipairs", "pairs", "next", "pcall", "xpcall",
            "select", "tonumber", "tostring", "type", "unpack", "rawequal", "rawget", "rawset", "getfenv",
            "setfenv", "loadstring", "collectgarbage", "print", "_VERSION", "newproxy", "gcinfo", "date", "time",
            "difftime", "tostringall", "geterrorhandler", "seterrorhandler", "debugstack", "debuglocals",
            "debugprofilestart", "debugprofilestop", "strsplit", "strjoin", "strconcat", "strtrim", "strsplittable",
            "strlen", "strsub", "strupper", "strlower", "strfind", "strmatch", "strrep", "strrev", "strbyte",
            "strchar", "gsub", "gmatch", "format", "tinsert", "tremove", "tContains", "tIndexOf", "wipe", "sort",
            "foreach", "foreachi", "getn", "abs", "ceil", "floor", "max", "min", "mod", "random", "sqrt", "sin",
            "cos", "tan", "asin", "acos", "atan", "atan2", "exp", "log", "log10", "fastrandom", "Mixin",
            "CreateFromMixins", "CountTable", "strlenutf8", "strcmputf8i", "rtgsub", "import"]
LUA_LIBS = {
    "string": ["byte", "char", "find", "format", "gmatch", "gsub", "len", "lower", "match", "rep", "reverse", "sub",
               "upper", "concat", "contains", "endswith", "startswith", "join", "ltrim", "rtrim", "trim", "split",
               "rtgsub", "strcmputf8i", "strlenutf8", "splittable"],
    "table": ["concat", "insert", "remove", "sort", "maxn", "contains", "count", "create", "freeze", "isfrozen",
              "getcountinfo", "indexof", "isempty", "keys", "values", "removemulti", "removeunordered",
              "removevalue", "wipe", "foreach", "foreachi", "getn"],
    "math": ["abs", "acos", "asin", "atan", "atan2", "ceil", "cos", "cosh", "deg", "exp", "floor", "fmod", "frexp",
             "huge", "ldexp", "log", "log10", "max", "min", "modf", "pi", "pow", "rad", "random", "randomseed",
             "sin", "sinh", "sqrt", "tan", "tanh", "clamp", "isfinite", "isinf", "isnan", "lerp", "normalize",
             "remap", "round", "saturate", "sign", "wrap"],
    "bit": ["arshift", "band", "bnot", "bor", "bxor", "lshift", "mod", "rshift"],
    "coroutine": ["create", "isyieldable", "resume", "running", "status", "wrap", "yield", "close"],
    "os": ["clock", "date", "difftime", "time"],
}
WRITABLE_TABLES = ["SlashCmdList", "StaticPopupDialogs", "UISpecialFrames", "UIPanelWindows", "_G", "BINDING_HEADER_OTHER"]


def _ok(name):
    return bool(IDENT.match(name))


def _lua_list(names, per_line=6):
    names = sorted({n for n in names if _ok(n)})
    out = []
    for i in range(0, len(names), per_line):
        out.append("  " + " ".join(f'"{n}",' for n in names[i:i + per_line]))
    return "\n".join(out)


def _fields_table(name, fields, strict=True, indent="  "):
    fl = sorted({f for f in fields if _ok(f)})
    body = ", ".join(f'"{f}"' for f in fl)
    extra = "" if strict else ", other_fields = true"
    return f'{indent}{name} = {{ fields = {{ {body} }}{extra} }},'


def addon_globals(addon_dir):
    folder, tocs = addon_tocs(addon_dir)
    g = set()
    for t in tocs:
        g.update(t.saved_variables())
        g.update(t.compartment_funcs().values())
        extra = t.get("X-Wowf-Globals")
        if extra:
            g.update(x.strip() for x in re.split(r"[,\s]+", extra) if x.strip())
    bindings = os.path.join(addon_dir, "Bindings.xml")
    if os.path.isfile(bindings):
        # functions the binding snippets call must be global
        text = open(bindings, encoding="utf-8", errors="replace").read()
        for body in re.findall(r"<Binding\b[^>]*>(.*?)</Binding>", text, re.S):
            g.update(n for n in re.findall(r"\b([A-Za-z_]\w*)\s*\(", body) if n[:1].isupper())
    for dirpath, dirnames, files in os.walk(addon_dir):
        dirnames[:] = [d for d in dirnames if d.lower() not in ("libs", "tests", ".git")]
        for f in files:
            if f.lower().endswith(".lua"):
                text = open(os.path.join(dirpath, f), encoding="utf-8", errors="replace").read()
                g.update(re.findall(r"\b(SLASH_[A-Za-z0-9_]+\d)\s*=", text))
                g.update(re.findall(r"^\s*(BINDING_(?:HEADER|NAME)_[A-Za-z0-9_]+)\s*=", text, re.M))
                g.update(re.findall(r"^function\s+([A-Za-z_]\w*_OnAddonCompartment\w*)\s*\(", text, re.M))
    return sorted(x for x in g if _ok(x))


def workspace_addons(root):
    out = []
    for d in sorted(os.listdir(root)):
        p = os.path.join(root, d)
        if os.path.isdir(p) and not d.startswith(".") and d not in ("tools", "dist"):
            if any(f.lower().endswith(".toc") for f in os.listdir(p)):
                out.append((d + "/", p))
    probe = os.path.join(root, ".claude", "skills", "wowf-debug", "assets", "WowfProbe")
    if os.path.isdir(probe):
        out.append((".claude/skills/wowf-debug/assets/WowfProbe/", probe))
    return out


def generate(root, I, extra_dirs=()):
    globals_ro = set()
    tables = {}  # name -> (fields set, strict)
    for (k, i), r in I.docs.items():
        if k == "fn" and r.get("global"):
            globals_ro.add(i)
        elif k == "ns":
            tables.setdefault(i, [set(), True])
        elif k == "fn" and r.get("ns"):
            tables.setdefault(r["ns"], [set(), True])[0].add(i.split(".", 1)[1])
    enum_fields = {}
    const_fields = {}
    for (k, i), r in I.docs.items():
        if k == "enum":
            enum_fields[i.split(".", 1)[1]] = set((r.get("v") or {}).keys())
        elif k == "const":
            const_fields[i.split(".", 1)[1]] = set((r.get("v") or {}).keys())
    for i, r in I.fx.items():
        if r.get("forever") is False:
            continue
        if "." in i:
            owner, member = i.split(".", 1)
            ent = tables.setdefault(owner, [set(), False])
            ent[0].add(member)
        else:
            globals_ro.add(i)
    for name in I.rt:
        parts = name.split(".")
        if len(parts) == 1:
            globals_ro.add(name)
        elif len(parts) == 2 and parts[0] not in ("Enum",):
            tables.setdefault(parts[0], [set(), True])[0].add(parts[1])
        elif len(parts) == 3 and parts[0] == "Enum":
            enum_fields.setdefault(parts[1], set()).add(parts[2])
    for lib in LUA_LIBS:
        tables.pop(lib, None)
    for t in ("Enum", "Constants") + tuple(WRITABLE_TABLES):
        tables.pop(t, None)
        globals_ro.discard(t)
    for t in tables:
        globals_ro.discard(t)

    lines = [
        f"-- GENERATED by tools/wowf/luacheckrc.py from API index {I.meta.get('build')} "
        f"(commit {str(I.meta.get('commit', ''))[:10]}), runtime probe {I.rt_meta.get('build', 'none')}. Do not edit.",
        'std = "wowlua+wowapi"',
        "max_line_length = false",
        "unused_args = false",
        "self = false",
        'ignore = { "542", "211/addonName", "211/ns", "212/self" }  -- empty if; namespace header; self',
        'exclude_files = { "**/Libs/**", "**/libs/**", "dist/**" }',
        "stds.wowlua = { read_globals = {",
        _lua_list(LUA_BASE),
    ]
    for lib, fields in LUA_LIBS.items():
        lines.append(_fields_table(lib, fields))
    lines.append("} }")
    lines.append("stds.wowapi = {")
    lines.append("globals = {")
    for t in WRITABLE_TABLES:
        lines.append(f'  {t} = {{ other_fields = true, read_only = false }},' if _ok(t) else "")
    lines.append("},")
    lines.append("read_globals = {")
    lines.append(_lua_list(globals_ro))
    for name in sorted(tables):
        if _ok(name):
            fields, strict = tables[name]
            lines.append(_fields_table(name, fields, strict))
    enum_entries = ", ".join(
        f'{e} = {{ fields = {{ {", ".join(chr(34) + f + chr(34) for f in sorted(v) if _ok(f))} }} }}'
        for e, v in sorted(enum_fields.items()) if _ok(e))
    lines.append(f"  Enum = {{ fields = {{ {enum_entries} }}, other_fields = true }},")
    const_entries = ", ".join(
        f'{e} = {{ fields = {{ {", ".join(chr(34) + f + chr(34) for f in sorted(v) if f and _ok(f))} }} }}'
        for e, v in sorted(const_fields.items()) if _ok(e))
    lines.append(f"  Constants = {{ fields = {{ {const_entries} }}, other_fields = true }},")
    lines.append("} }")
    for rel, path in list(workspace_addons(root)) + list(extra_dirs):
        g = addon_globals(path)
        if g:
            lines.append(f'files["{rel}"] = {{ globals = {{ {", ".join(chr(34) + x + chr(34) for x in g)} }} }}')
    return "\n".join(l for l in lines if l is not None) + "\n"


def ensure(root, I, force=False):
    path = os.path.join(root, ".luacheckrc")
    content = generate(root, I)
    if force or not os.path.isfile(path) or open(path, encoding="utf-8").read() != content:
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(content)
    return path
