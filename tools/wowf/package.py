"""Package an addon for CurseForge.

  python tools/wowf/cli.py package ADDON [--skip-lint]

- ADDON is a workspace folder name, an absolute path, or a path from the current
  directory (`.` inside the addon's own folder)
- lint gate: refuses to package while the Forever lint reports errors
- refuses dev-only addons (## X-Wowf-DevOnly: 1)
- writes dist/<Addon>-<Version>.zip with ONE root folder named like the TOC
  (CurseForge and its app require this), leaving out personal and dev files,
  dot-folders (.claude) and the agent notes (CLAUDE.md, AGENTS.md)
- refuses when those rules would leave out a file the TOC loads, or the TOC's
  IconTexture (a listed file under tests/, say)
"""
import argparse
import fnmatch
import os
import sys
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import config  # noqa: E402

EXCLUDE_DIRS = {"screenshots", ".git", ".github", "tests", "dist", "__pycache__", ".vscode", ".idea"}
EXCLUDE_FILES = ["*.psd", "*.xcf", "*.bak", "*.tmp", "desktop.ini", "Thumbs.db", ".DS_Store", ".luacheckrc",
                 ".pkgmeta", ".gitignore", ".gitattributes", "*-conflict*", "*.orig",
                 "CLAUDE.md", "CLAUDE.local.md", "AGENTS.md"]


def toc_fields(path):
    out = {}
    with open(path, encoding="utf-8-sig") as f:
        for line in f:
            if line.startswith("## ") and ":" in line:
                k, v = line[3:].split(":", 1)
                out[k.strip()] = v.strip()
    return out


def toc_files(path):
    """The files a TOC loads (its lines that aren't comments), with forward slashes. Lines with [conditions]
    or [Family]/[Game] tokens are left out: which file they mean depends on the client."""
    out = []
    with open(path, encoding="utf-8-sig") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "[" not in line:
                out.append(line.replace("\\", "/"))
    return out


def unpackaged(addon_dir, name, fields, files):
    """TOC-loaded files and the IconTexture that the zip would leave out."""
    packaged = {os.path.relpath(p, addon_dir).replace(os.sep, "/").lower() for p in files}
    missing = [f for f in toc_files(os.path.join(addon_dir, name + ".toc")) if f.lower() not in packaged]
    icon = fields.get("IconTexture", "").replace("\\", "/")
    prefix = f"interface/addons/{name.lower()}/"
    if icon.lower().startswith(prefix):
        rel = icon[len(prefix):].lower()
        stems = {os.path.splitext(p)[0] for p in packaged}
        if rel not in packaged and rel not in stems:   # WoW finds Media/Icon as Media/Icon.tga or .blp
            missing.append(icon)
    return missing


def collect(addon_dir):
    files = []
    for dirpath, dirnames, filenames in os.walk(addon_dir):
        dirnames[:] = sorted(d for d in dirnames if d.lower() not in EXCLUDE_DIRS and not d.startswith("."))
        for name in sorted(filenames):
            if any(fnmatch.fnmatch(name, pat) for pat in EXCLUDE_FILES):
                continue
            files.append(os.path.join(dirpath, name))
    return files


def build_zip(addon_dir, out_dir):
    name = os.path.basename(os.path.normpath(addon_dir))
    toc = os.path.join(addon_dir, name + ".toc")
    if not os.path.isfile(toc):
        raise SystemExit(f"package: {name}.toc not found; folder and TOC names must match")
    fields = toc_fields(toc)
    if fields.get("X-Wowf-DevOnly") == "1":
        raise SystemExit(f"package: {name} is a dev-only addon and is never published")
    version = fields.get("Version")
    if not version:
        raise SystemExit("package: the TOC has no ## Version")
    files = collect(addon_dir)
    missing = unpackaged(addon_dir, name, fields, files)
    if missing:
        raise SystemExit("package: the zip would leave out what the TOC loads: " + ", ".join(missing))
    os.makedirs(out_dir, exist_ok=True)
    zip_path = os.path.join(out_dir, f"{name}-{version}.zip")
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        for path in files:
            rel = os.path.relpath(path, addon_dir).replace(os.sep, "/")
            z.write(path, f"{name}/{rel}")
    return zip_path, version, files


def resolve_addon(arg, root):
    """Absolute path, a folder from the current directory that holds its own TOC
    (so `.` works inside the addon), else a folder name under the workspace root."""
    if os.path.isabs(arg):
        return os.path.normpath(arg)
    here = os.path.abspath(arg)
    if os.path.isfile(os.path.join(here, os.path.basename(here) + ".toc")):
        return here
    return os.path.normpath(os.path.join(root, arg))


def main(argv):
    p = argparse.ArgumentParser(prog="wowf package")
    p.add_argument("addon")
    p.add_argument("--skip-lint", action="store_true")
    a = p.parse_args(argv)
    cfg = config.load()
    root = cfg["_root"]
    addon_dir = resolve_addon(a.addon, root)
    if not a.skip_lint:
        import index as idx
        import lint
        findings, _, _ = lint.lint_dir(addon_dir, cfg, idx.Index(root))
        errors = [f for f in findings if f.sev == "E"]
        if errors:
            for f in errors:
                print(f.text(root))
            print(f"package: {len(errors)} lint error(s); fix them first")
            return 1
    zip_path, version, files = build_zip(addon_dir, os.path.join(root, "dist"))
    size = os.path.getsize(zip_path)
    print(f"wrote {zip_path}  ({len(files)} files, {size // 1024} KB, version {version})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
