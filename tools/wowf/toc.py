"""TOC file parsing for addon folders."""
import os
import re

_DIRECTIVE = re.compile(r"^##\s*([^:]+?)\s*:\s*(.*?)\s*$")
_INLINE = re.compile(r"\[([A-Za-z]+)(?:\s+([^\]]*))?\]")

SUFFIXES = ["_Camelot", "-Camelot", "_Forever", "-Forever", "_Mainline", "-Mainline", "_Standard", "-Standard",
            "_Classic", "-Classic", "_Vanilla", "-Vanilla", "_TBC", "-TBC", "_Wrath", "-Wrath", "_Cata", "-Cata",
            "_Mists", "-Mists", "_WoWLabs", "_Plunderstorm"]
# Which TOC the Forever client loads, best first (game type beats family beats bare).
FOREVER_PRECEDENCE = ["_Camelot", "-Camelot", "_Forever", "-Forever", "_Mainline", "-Mainline", ""]


class Toc:
    def __init__(self, path):
        self.path = path
        self.name = os.path.basename(path)[:-4]
        with open(path, "rb") as fh:
            self.raw = fh.read()
        self.has_bom = self.raw.startswith(b"\xef\xbb\xbf")
        text = self.raw.decode("utf-8", "replace").lstrip("﻿")
        self.directives = {}      # lower key -> last value (inline conditions stripped)
        self.directive_lines = {} # lower key -> line number
        self.files = []           # (line_no, path_with_vars_expanded, inline_dict)
        self.unknown_tokens = []  # (line_no, token)
        for n, line in enumerate(text.splitlines(), 1):
            s = line.strip()
            if not s:
                continue
            m = _DIRECTIVE.match(s)
            if m:
                key = m.group(1).strip().lower()
                self.directives[key] = _INLINE.sub("", m.group(2)).strip()
                self.directive_lines[key] = n
                continue
            if s.startswith("#"):
                continue
            inline = {}
            for k, v in _INLINE.findall(s):
                if k.lower() in ("allowloadgametype", "excludeloadgametype", "allowload", "allowloadtextlocale", "bootstrap"):
                    inline[k.lower()] = v
            path = _INLINE.sub(lambda m: {"family": "Mainline", "game": "Camelot", "textlocale": "enUS"}.get(m.group(1).lower(), "") if not m.group(2) else "", s).strip()
            self.files.append((n, path.replace("/", "\\"), inline))

    def get(self, key, default=None):
        return self.directives.get(key.lower(), default)

    def interfaces(self):
        v = self.get("interface", "")
        return [int(x) for x in re.findall(r"\d+", v)]

    def saved_variables(self):
        names = []
        for key in ("savedvariables", "savedvariablespercharacter"):
            names += [x.strip() for x in re.split(r"[,\s]+", self.get(key, "")) if x.strip()]
        return names

    def compartment_funcs(self):
        return {k: self.get(k) for k in ("addoncompartmentfunc", "addoncompartmentfunconenter", "addoncompartmentfunconleave") if self.get(k)}

    def suffix(self, folder):
        rest = self.name[len(folder):] if self.name.lower().startswith(folder.lower()) else None
        return rest


def addon_tocs(addon_dir):
    folder = os.path.basename(os.path.normpath(addon_dir))
    out = []
    for f in sorted(os.listdir(addon_dir)):
        if f.lower().endswith(".toc"):
            t = Toc(os.path.join(addon_dir, f))
            out.append(t)
    return folder, out


def forever_toc(addon_dir):
    """The TOC the Forever client will load (by suffix precedence), or None."""
    folder, tocs = addon_tocs(addon_dir)
    by_suffix = {}
    for t in tocs:
        sfx = t.suffix(folder)
        if sfx is not None:
            by_suffix[sfx.lower()] = t
    for sfx in FOREVER_PRECEDENCE:
        if sfx.lower() in by_suffix:
            return by_suffix[sfx.lower()]
    return None
