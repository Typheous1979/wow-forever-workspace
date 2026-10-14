"""Build MusicForever's music catalog from Forever game data (wago.tools).

  python tools/wowf/cli.py music-catalog fetch [--build B]      DB2 CSVs + file heads into the cache
  python tools/wowf/cli.py music-catalog build [--build B] [--out PATH] [--zones A,B]
  python tools/wowf/cli.py music-catalog show [--build B]       print the hierarchy

Data path: AreaTable.ZoneMusic -> ZoneMusic.Sounds_0/1 (day/night SoundKit) ->
SoundKitEntry -> FileDataID; ZoneIntroMusicTable for intros; every SoundKit with
SoundType 28 (music) for the rest.  Track names, album and length come from each
file's first 64 KB (ID3 tags + MP3 Xing/Info header); the server filename comes
from content-disposition.  Only IDs, names and lengths are emitted, never audio.
"""
import argparse
import csv
import json
import os
import re
import struct
import sys
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import config  # noqa: E402

MUSIC_DIR = os.path.join(config.CACHE_DIR, "music")
WAGO = "https://wago.tools"
UA = "wowf-tools/0.1 (+https://github.com/Typheous1979/wow-forever-workspace)"
DEFAULT_BUILD = "1.60.1.70245"
TABLES = ("AreaTable", "WMOAreaTable", "ZoneMusic", "SoundKitEntry", "SoundKit", "ZoneIntroMusicTable", "Map")
MUSIC_SOUNDTYPE = "28"
HEAD_BYTES = 65536


# ---------------------------------------------------------------- fetching

def _get(url, limit=None):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=120) as r:
        name = None
        cd = r.headers.get("content-disposition") or ""
        m = re.search(r'filename="?([^";]+)', cd)
        if m:
            name = m.group(1).strip()
        if limit is None:
            return r.read(), name, True
        data = r.read(limit)
        complete = len(data) < limit or not r.read(1)
        return data, name, complete


def csv_dir(build):
    return os.path.join(MUSIC_DIR, "csv", build)


def fetch_tables(build, log=print):
    d = csv_dir(build)
    os.makedirs(d, exist_ok=True)
    for t in TABLES:
        path = os.path.join(d, t + ".csv")
        if os.path.isfile(path):
            continue
        data, _, _ = _get(f"{WAGO}/db2/{t}/csv?build={build}")
        if not data.startswith(b"ID,"):
            raise SystemExit(f"music-catalog: unexpected response for {t}: {data[:80]!r}")
        with open(path, "wb") as f:
            f.write(data)
        log(f"fetched {t} ({data.count(b'\n')} rows)")
        time.sleep(0.5)


def read_table(build, name):
    with open(os.path.join(csv_dir(build), name + ".csv"), encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f))


def head_path(fid):
    return os.path.join(MUSIC_DIR, "heads", f"{fid}.bin")


def meta_path(build):
    return os.path.join(MUSIC_DIR, f"filemeta-{build}.json")


def fetch_file_meta(build, fids, log=print, delay=0.2):
    """Parse metadata for each FileDataID, downloading only what is missing."""
    path = meta_path(build)
    meta = {}
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as f:
            meta = json.load(f)
    os.makedirs(os.path.dirname(head_path(0)), exist_ok=True)
    todo = [f for f in fids if not (meta.get(str(f)) or {}).get("seconds")]  # new, or retry no-length
    for i, fid in enumerate(todo, 1):
        try:
            url = f"{WAGO}/api/casc/{fid}?download&build={build}"
            data, name, complete = _get(url, HEAD_BYTES)
            if not data:
                # encrypted in this build's CDN data (the client has the key): any build will do
                url = f"{WAGO}/api/casc/{fid}?download"
                data, name2, complete = _get(url, HEAD_BYTES)
                name = name or name2
            info = describe_audio(data, complete) if data else {"error": "empty"}
            if info.get("seconds") is None and data and not complete:
                full, _, _ = _get(url)
                info = describe_audio(full, True)
        except Exception as e:  # missing on this build, network, ...
            info = {"error": str(e)[:120]}
            name = None
        info["file"] = name
        meta[str(fid)] = info
        if i % 25 == 0 or i == len(todo):
            log(f"  file metadata {i}/{len(todo)}")
            _save_json(path, meta)
        time.sleep(delay)
    _save_json(path, meta)
    return meta


def _save_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f, indent=0, sort_keys=True)
    os.replace(tmp, path)


# ---------------------------------------------------------------- audio parsing

def _syncsafe(b):
    return (b[0] & 127) << 21 | (b[1] & 127) << 14 | (b[2] & 127) << 7 | (b[3] & 127)


def parse_id3(data):
    """Return ({frame: text}, tag_size) for an ID3v2.3/2.4 tag, else ({}, 0)."""
    if len(data) < 10 or data[:3] != b"ID3":
        return {}, 0
    ver = data[3]
    size = _syncsafe(data[6:10])
    end = min(10 + size, len(data))
    out, i = {}, 10
    while i + 10 <= end:
        fid = data[i:i + 4]
        if not fid.strip(b"\0") or not fid.isalnum():
            break
        n = _syncsafe(data[i + 4:i + 8]) if ver == 4 else struct.unpack(">I", data[i + 4:i + 8])[0]
        body = data[i + 10:i + 10 + n]
        i += 10 + n
        if fid[:1] != b"T" or not body:
            continue
        enc, raw = body[0], body[1:]
        codec = {0: "latin-1", 1: "utf-16", 2: "utf-16-be", 3: "utf-8"}.get(enc, "latin-1")
        out[fid.decode()] = raw.decode(codec, "replace").strip("\0").strip()
    return out, 10 + size


_BITRATES = {  # MPEG1 / MPEG2(.5) layer III, kbps
    3: [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0],
    2: [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0],
}
_RATES = {3: [44100, 48000, 32000], 2: [22050, 24000, 16000], 0: [11025, 12000, 8000]}


def mp3_seconds(data, offset, total_len=None):
    """Duration from the Xing/Info or VBRI header of the first frame; CBR fallback needs total_len."""
    j = offset
    while j + 4 <= len(data) and not (data[j] == 0xFF and data[j + 1] & 0xE0 == 0xE0):
        j += 1
    if j + 4 > len(data):
        return None
    h = data[j:j + 4]
    version = (h[1] >> 3) & 3
    if version == 1 or ((h[1] >> 1) & 3) != 1:  # reserved version / not layer III
        return None
    rate_idx = (h[2] >> 2) & 3
    if rate_idx == 3:
        return None
    rate = _RATES[version][rate_idx]
    spf = 1152 if version == 3 else 576
    mono = (h[3] >> 6) == 3
    side = (17 if mono else 32) if version == 3 else (9 if mono else 17)
    xing = j + 4 + side
    tag = data[xing:xing + 4]
    if tag in (b"Xing", b"Info") and data[xing + 7] & 1:
        frames = struct.unpack(">I", data[xing + 8:xing + 12])[0]
        return frames * spf / rate
    if data[j + 36:j + 40] == b"VBRI":
        frames = struct.unpack(">I", data[j + 50:j + 54])[0]
        return frames * spf / rate
    kbps = _BITRATES[3 if version == 3 else 2][h[2] >> 4]
    if total_len and kbps:
        return (total_len - j) * 8 / (kbps * 1000)
    return None


def ogg_seconds(data):
    """Duration of a complete Ogg Vorbis file (last page granule / sample rate)."""
    if data[:4] != b"OggS":
        return None
    k = data.find(b"\x01vorbis")
    if k < 0:
        return None
    rate = struct.unpack("<I", data[k + 12:k + 16])[0]
    last = data.rfind(b"OggS")
    if last < 0 or not rate:
        return None
    granule = struct.unpack("<q", data[last + 6:last + 14])[0]
    return granule / rate if granule > 0 else None


def describe_audio(data, complete):
    if data[:4] == b"OggS":
        secs = ogg_seconds(data) if complete else None
        return {"fmt": "ogg", "seconds": _round(secs)}
    tags, off = parse_id3(data)
    secs = mp3_seconds(data, off, len(data) if complete else None)
    return {"fmt": "mp3", "seconds": _round(secs), "title": tags.get("TIT2"), "album": tags.get("TALB"),
            "artist": tags.get("TPE1"), "year": tags.get("TYER") or tags.get("TDRC")}


def _round(x):
    return None if x is None else round(x, 1)


# ---------------------------------------------------------------- hierarchy

AREA_FLAG_CAPITAL = 0x100
INSTANCE_GROUPS = {"1": "Dungeons", "2": "Raids", "3": "Battlegrounds", "4": "Scenarios"}
TOP_ORDER = ["Zones", "Cities", "Dungeons", "Raids", "Battlegrounds", "Scenarios", "Music Sets", "Other Music"]
SECTION_ORDER = {"Day": 0, "Night": 1, "Music": 2, "Intro": 3}
_JUNK_MAP = re.compile(r"test|<unused>|nothing to see|preserved|\(winter\)|phase\)", re.I)


def node(name):
    return {"name": name, "children": [], "tracks": []}


_JUNK_AREA = re.compile(r"unused|\[ph\]|\bdnt\b|\btest\b|zzold|\bold\b", re.I)


def child(parent, name):
    for c in parent["children"]:
        if c["name"].lower() == name.lower():
            return c
    c = node(name)
    parent["children"].append(c)
    return c


def _add_tracks(n, fids):
    for f in fids:
        if f not in n["tracks"]:
            n["tracks"].append(f)


def set_kind(s):
    """Folder for a ZoneMusic SetName: Zone, Moment, Dungeon, Raid, PvP or Other."""
    s = re.sub(r"^\d+(\.\d+)*\s*", "", s).lower()
    for key, label in (("dungeon", "Dungeon"), ("raid", "Raid"), ("pvp", "PvP"), ("moment", "Moment"), ("zone", "Zone")):
        if s.startswith(key) or (key in ("pvp", "raid") and key in s):
            return label
    return "Other"


def pretty_set_name(s):
    s = re.sub(r"^\d+(\.\d+)*\s*", "", s)  # "1.60 Dungeon - X" -> "Dungeon - X"
    s = re.sub(r"^(Zone|ZoneMusic|Moment|Dungeon|Raid)[-_ ]*", "", s, flags=re.I)
    s = re.sub(r"^[-_ ]+", "", s)
    s = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", s.replace("_", " ").replace("-", " "))
    return re.sub(r"\s+", " ", s).strip() or "Unnamed"


_GLUED_WORDS = ("day", "night", "barren", "dry", "evil", "forest", "desert", "plains", "jungle", "mountain",
                "volcanic", "haunted", "swamp", "cursed", "land", "enchanted", "soggy", "magic", "mystery",
                "gloomy", "battle", "cave", "tavern", "elf", "dwarf", "human", "orc", "undead", "walking")


def _split_glued(word):
    """'daybarrendry' -> 'day barren dry' when it splits completely into known words."""
    low = word.lower()
    out, i = [], 0
    while i < len(low):
        for w in sorted(_GLUED_WORDS, key=len, reverse=True):
            if low.startswith(w, i):
                out.append(w)
                i += len(w)
                break
        else:
            return word
    return " ".join(out) if len(out) > 1 else word


def pretty_file_name(path):
    base = os.path.splitext(os.path.basename(path or ""))[0]
    base = re.sub(r"_\d{5,}$", "", base)                       # trailing "_6861013" file ID
    base = re.sub(r"^mus_", "", base, flags=re.I)
    base = re.sub(r"^(c|\d+(\.\d+)*)[_ -]+", "", base, flags=re.I)  # "c_", "100_", "1.15.7 - "
    base = re.sub(r"^(raid|dungeon)[_ -]+", "", base, flags=re.I)
    base = base.replace("_", " ").replace("-", " ")
    base = re.sub(r"(?<=[a-z])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])", " ", base)  # AQTriangle -> AQ Triangle
    base = re.sub(r"(?<=[a-zA-Z])(?=\d)", " ", base)
    base = " ".join(_split_glued(w) for w in re.sub(r"\s+", " ", base).strip().split(" "))
    return " ".join(w if (w.isupper() and len(w) > 1) else w.capitalize() for w in base.split(" "))


def track_name(info, fid):
    """Prefer a real ID3 title ("Signpost- Ogrimmar"); fall back to the file name."""
    info = info or {}
    title = (info.get("title") or "").strip()
    stem = os.path.splitext(info.get("file") or "")[0].lower()
    if title and title.lower().replace(" ", "") != stem.replace(" ", "") and not re.search(r"[_]|\d-?(zone|moment)$", title.lower()):
        return title if " " in title else pretty_file_name(title)
    return pretty_file_name(info.get("file")) or title or f"Track {fid}"


class Data:
    def __init__(self, build):
        self.build = build
        self.areas = {r["ID"]: r for r in read_table(build, "AreaTable")}
        self.maps = {r["ID"]: r for r in read_table(build, "Map")}
        self.zm = {r["ID"]: r for r in read_table(build, "ZoneMusic")}
        self.intro = {r["ID"]: r for r in read_table(build, "ZoneIntroMusicTable")}
        self.kit_type = {r["ID"]: r["SoundType"] for r in read_table(build, "SoundKit")}
        self.kit_files = {}
        for r in sorted(read_table(build, "SoundKitEntry"), key=lambda r: int(r["ID"])):
            self.kit_files.setdefault(r["SoundKitID"], []).append(int(r["FileDataID"]))
        self.kids = {}
        for a in self.areas.values():
            self.kids.setdefault(a["ParentAreaID"], []).append(a)
        # indoor (WMO) music, attached to its AreaTable row when it names one
        self.wmo = {}
        for w in read_table(build, "WMOAreaTable"):
            if w["AreaTableID"] != "0" and (w["ZoneMusic"] != "0" or w["IntroSound"] != "0"):
                self.wmo.setdefault(w["AreaTableID"], []).append(
                    {"ID": "wmo" + w["ID"], "AreaName_lang": w["AreaName_lang"].strip(),
                     "ZoneMusic": w["ZoneMusic"], "IntroSound": w["IntroSound"]})

    def music_kits(self):
        kits = {k for k, t in self.kit_type.items() if t == MUSIC_SOUNDTYPE}
        kits |= {r["SoundID"] for r in self.intro.values()}
        return kits

    def all_music_files(self):
        out = set()
        for k in self.music_kits():
            out.update(self.kit_files.get(k, []))
        return sorted(out)

    def files(self, kit):
        return list(self.kit_files.get(kit, [])) if kit and kit != "0" else []

    def sections(self, area):
        """[(label, fids)] for one area: Day/Night (or Music) and Intro."""
        out = []
        z = self.zm.get(area["ZoneMusic"])
        if z:
            day, night = self.files(z["Sounds_0"]), self.files(z["Sounds_1"])
            if day == night or not night:
                out.append(("Music", day))
            elif not day:
                out.append(("Night", night))
            else:
                out += [("Day", day), ("Night", night)]
        i = self.intro.get(area["IntroSound"])
        if i:
            out.append(("Intro", self.files(i["SoundID"])))
        return [(lbl, f) for lbl, f in out if f]

    def signature(self, area):
        return (area["ZoneMusic"], area["IntroSound"])


def _fill_area(d, n, area, depth=0):
    """Put an area's sections on node n; subareas whose music differs become children."""
    # own music always goes into section children; _prune hoists a lone section
    for lbl, fids in d.sections(area):
        _add_tracks(child(n, lbl), fids)
    for w in d.wmo.get(area["ID"], []):
        wname = w["AreaName_lang"]
        if not wname or wname.lower() == area["AreaName_lang"].lower():
            for lbl, fids in d.sections(w):
                _add_tracks(child(n, lbl), fids)
        elif not _JUNK_AREA.search(wname):
            _fill_area(d, child(n, wname), w, depth + 1)
    sig = d.signature(area)
    _descend(d, n, area, sig, depth)


def _descend(d, n, area, sig, depth):
    if depth > 5:
        return
    for sub in sorted(d.kids.get(area["ID"], []), key=lambda a: a["AreaName_lang"]):
        if _JUNK_AREA.search(sub["AreaName_lang"]):
            continue
        if d.sections(sub) and d.signature(sub) != sig:
            _fill_area(d, child(n, sub["AreaName_lang"]), sub, depth + 1)
        else:
            _descend(d, n, sub, sig, depth + 1)


def _prune(n):
    n["children"] = [c for c in n["children"] if _prune(c)]
    n["children"].sort(key=lambda c: (SECTION_ORDER.get(c["name"], 9), c["name"]))
    # a node whose only child is a single section: hoist the tracks
    if not n["tracks"] and len(n["children"]) == 1 and n["children"][0]["name"] in SECTION_ORDER \
            and not n["children"][0]["children"]:
        n["tracks"] = n["children"][0]["tracks"]
        n["children"] = []
    return bool(n["tracks"] or n["children"])


def _walk(n):
    yield n
    for c in n["children"]:
        yield from _walk(c)


def build_tree(d, only_zones=None):
    top = {name: node(name) for name in TOP_ORDER}
    seen_zone_names = set()

    # open world; lower map IDs (Eastern Kingdoms, Kalimdor) claim duplicate zone names
    world_maps = sorted((m for m in d.maps.values()
                         if m["InstanceType"] == "0" and not _JUNK_MAP.search(m["MapName_lang"])),
                        key=lambda m: int(m["ID"]))
    for m in world_maps:
        for a in sorted(d.kids.get("0", []), key=lambda a: a["AreaName_lang"]):
            name = a["AreaName_lang"]
            if a["ContinentID"] != m["ID"] or name in seen_zone_names or _JUNK_AREA.search(name):
                continue
            if only_zones and name not in only_zones:
                continue
            if int(a["Flags_0"]) & AREA_FLAG_CAPITAL:
                n = child(top["Cities"], name)
            else:
                n = child(child(top["Zones"], m["MapName_lang"]), name)
            _fill_area(d, n, a)
            if n["tracks"] or n["children"]:
                seen_zone_names.add(name)

    if not only_zones:
        for m in sorted(d.maps.values(), key=lambda m: m["MapName_lang"]):
            group = INSTANCE_GROUPS.get(m["InstanceType"])
            if not group or _JUNK_MAP.search(m["MapName_lang"]):
                continue
            n = child(top[group], m["MapName_lang"])
            for a in sorted(d.kids.get("0", []), key=lambda a: a["AreaName_lang"]):
                if a["ContinentID"] != m["ID"]:
                    continue
                _fill_area(d, n if a["AreaName_lang"] == m["MapName_lang"] else child(n, a["AreaName_lang"]), a)

        sets = top["Music Sets"]
        for z in sorted(d.zm.values(), key=lambda z: pretty_set_name(z["SetName"])):
            day, night = d.files(z["Sounds_0"]), d.files(z["Sounds_1"])
            n = child(child(sets, set_kind(z["SetName"])), pretty_set_name(z["SetName"]))
            if day == night or not night:
                _add_tracks(n, day)
            else:
                _add_tracks(child(n, "Day"), day)
                _add_tracks(child(n, "Night"), night)
        intros = child(sets, "Intros")
        for i in sorted(d.intro.values(), key=lambda i: i["Name"]):
            _add_tracks(child(intros, i["Name"]), d.files(i["SoundID"]))

        used = set()
        for n in top.values():
            for x in _walk(n):
                used.update(x["tracks"])
        _add_tracks(top["Other Music"], [f for f in d.all_music_files() if f not in used])

    root = node("MusicForever")
    for name in TOP_ORDER:
        if _prune(top[name]):
            root["children"].append(top[name])
    return root


# ---------------------------------------------------------------- Lua output

FLAG_FOREVER = 1  # file not referenced by live retail: new or remastered for Forever


def live_file_ids():
    """FileDataIDs that live retail's SoundKitEntry references (cached CSV), or None."""
    path = os.path.join(MUSIC_DIR, "csv", "live", "SoundKitEntry.csv")
    if not os.path.isfile(path):
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            data, _, _ = _get(f"{WAGO}/db2/SoundKitEntry/csv")
            with open(path, "wb") as f:
                f.write(data)
        except Exception:
            return None
    with open(path, encoding="utf-8", newline="") as f:
        return {int(r["FileDataID"]) for r in csv.DictReader(f)}


def lua_str(s):
    s = s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "")
    return '"' + s + '"'  # UTF-8 bytes are fine inside a Lua string


def _lua_node(n, out, depth):
    pad = "    " * depth
    parts = [lua_str(n["name"])]
    kids = n["children"]
    tracks = n["tracks"]
    if not kids:
        out.append(f"{pad}{{{parts[0]}, nil, {{{', '.join(map(str, tracks))}}}}},")
        return
    out.append(f"{pad}{{{parts[0]}, {{")
    for c in kids:
        _lua_node(c, out, depth + 1)
    tail = f"{{{', '.join(map(str, tracks))}}}" if tracks else "nil"
    out.append(f"{pad}}}, {tail}}},")


def emit_lua(root, meta, build, live_ids, generated):
    """Data/Catalog.lua: ns.CatalogTracks[fileID] = {name, seconds, flags}; ns.CatalogTree nodes are
    {name, children or nil, trackIDs or nil}."""
    used = sorted({f for x in _walk(root) for f in x["tracks"]})
    lines = [
        "local addonName, ns = ...",
        "",
        "-- GENERATED by tools/wowf/music_catalog.py. Do not edit by hand.",
        f"-- Source: Forever build {build} game tables (wago.tools), generated {generated}.",
        "-- Contains FileDataIDs, names and lengths only; the game client streams the audio.",
        "",
        f'ns.CatalogBuild = "{build}"',
        "",
        "-- [fileID] = { name, seconds (0 = unknown), flags (1 = Forever music) }",
        "local T = {}",
        "ns.CatalogTracks = T",
    ]
    flags = {f: FLAG_FOREVER if (live_ids is not None and f not in live_ids) else 0 for f in used}
    names = {f: track_name(meta.get(str(f)), f) for f in used}
    seen = {}
    for f in used:  # identical names within one version get (2), (3)... in FileDataID order
        key = (names[f], flags[f])
        seen[key] = seen.get(key, 0) + 1
        if seen[key] > 1:
            names[f] = f"{names[f]} ({seen[key]})"
    for f in used:
        secs = (meta.get(str(f)) or {}).get("seconds") or 0
        lines.append(f"T[{f}] = {{{lua_str(names[f])}, {secs:g}, {flags[f]}}}")
    lines += ["", "-- { name, children or nil, trackIDs or nil }", "ns.CatalogTree = {"]
    for c in root["children"]:
        _lua_node(c, lines, 1)
    lines.append("}")
    return "\n".join(lines) + "\n", len(used)


# ---------------------------------------------------------------- unplayable files

def excluded_path():
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "music_unplayable.json")


def load_excluded():
    path = excluded_path()
    if not os.path.isfile(path):
        return {"ids": []}
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def prune_tree(root, excluded):
    """Drop excluded FileDataIDs everywhere, then empty folders."""
    bad = set(excluded)
    for n in _walk(root):
        n["tracks"] = [f for f in n["tracks"] if f not in bad]
    root["children"] = [c for c in root["children"] if _prune(c)]
    return root


def verify_results(cfg):
    """MusicForeverDB.verify from every client's account SavedVariables."""
    import savedvars
    out = []
    for key, client in config.discover_clients(cfg).items():
        for scope, label, path in savedvars.find_sv_files(client["dir"], "MusicForever"):
            if scope != "account":
                continue
            v = (savedvars.load_sv(path).get("MusicForeverDB") or {}).get("verify")
            if isinstance(v, dict):
                out.append((key, path, v))
    return out


def prune_from_probe(cfg, log=print):
    """Merge silent IDs from a trustworthy /mf verify run into data/music_unplayable.json."""
    data = load_excluded()
    ids = set(data.get("ids", []))
    used = 0
    for key, path, v in verify_results(cfg):
        controls = v.get("controls") or {}
        if v.get("method") != "isplaying" or not v.get("done") or not controls \
                or any(bool(x) for x in controls.values()):
            log(f"{key}: skipping {path}: run not complete, or its controls did not come back silent")
            continue
        silent = v.get("silent") or {}
        silent = list(silent.values()) if isinstance(silent, dict) else list(silent)
        ids.update(int(x) for x in silent)
        data.setdefault("evidence", {})[f"{key} {v.get('version')}.{v.get('build')}"] = {
            "catalog": v.get("catalog"), "playing": v.get("played"), "silent": len(silent)}
        used += 1
    if not used:
        log("no usable /mf verify results found")
        return 1
    data["ids"] = sorted(ids)
    data["note"] = ("FileDataIDs that C_Sound.IsPlaying reports silent on Forever (encrypted or absent "
                    "on the client), from MusicForever /mf verify. Excluded from Data/Catalog.lua.")
    with open(excluded_path(), "w", encoding="utf-8", newline="\n") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")
    log(f"wrote {excluded_path()}: {len(data['ids'])} unplayable IDs")
    return 0


# ---------------------------------------------------------------- CLI

def _print_tree(n, depth, maxd, meta):
    total = sum(len(x["tracks"]) for x in _walk(n))
    print("  " * depth + f"{n['name']}  ({total})")
    if depth >= maxd:
        return
    for c in n["children"]:
        _print_tree(c, depth + 1, maxd, meta)
    for f in n["tracks"]:
        info = meta.get(str(f)) or {}
        print("  " * (depth + 1) + f"- {track_name(info, f)}  [{f}] {info.get('seconds')}s")


def main(argv):
    p = argparse.ArgumentParser(prog="wowf music-catalog")
    p.add_argument("action", choices=["fetch", "build", "show"])
    p.add_argument("--build", default=DEFAULT_BUILD)
    p.add_argument("--zones", help="comma-separated zone names (spike/testing)")
    p.add_argument("--depth", type=int, default=2)
    p.add_argument("--out", help="output Lua path (default: MusicForever/Data/Catalog.lua)")
    p.add_argument("--prune-from-probe", action="store_true",
                   help="first merge silent IDs from the client's /mf verify results into data/music_unplayable.json")
    a = p.parse_args(argv)
    if a.prune_from_probe and prune_from_probe(config.load()):
        return 1
    fetch_tables(a.build)
    d = Data(a.build)
    if a.action == "fetch":
        meta = fetch_file_meta(a.build, d.all_music_files())
        bad = [k for k, v in meta.items() if v.get("error") or not v.get("seconds")]
        print(f"{len(meta)} files described; {len(bad)} without a length")
        return 0
    only = set(a.zones.split(",")) if a.zones else None
    root = prune_tree(build_tree(d, only), load_excluded().get("ids", []))
    meta_file = meta_path(a.build)
    meta = {}
    if os.path.isfile(meta_file):
        with open(meta_file, encoding="utf-8") as f:
            meta = json.load(f)
    if a.action == "show":
        for c in root["children"]:
            _print_tree(c, 0, a.depth, meta)
        return 0
    missing = [f for x in _walk(root) for f in x["tracks"] if str(f) not in meta]
    if missing:
        print(f"{len(set(missing))} files have no metadata yet; run: music-catalog fetch")
        return 1
    cfg = config.load()
    out = a.out or os.path.join(cfg["_root"], "MusicForever", "Data", "Catalog.lua")
    text, n = emit_lua(root, meta, a.build, live_file_ids(), time.strftime("%Y-%m-%d"))
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print(f"wrote {out}: {n} tracks, {len(text.encode('utf-8')) // 1024} KB")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
