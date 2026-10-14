"""Package an addon for CurseForge.

  python tools/wowf/cli.py package ADDON [--skip-lint]

- lint gate: refuses to package while the Forever lint reports errors
- refuses dev-only addons (## X-Wowf-DevOnly: 1)
- writes dist/<Addon>-<Version>.zip with ONE root folder named like the TOC
  (CurseForge and its app require this), leaving out personal and dev files
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
                 ".pkgmeta", ".gitignore", ".gitattributes", "*-conflict*", "*.orig"]


def toc_fields(path):
    out = {}
    with open(path, encoding="utf-8-sig") as f:
        for line in f:
            if line.startswith("## ") and ":" in line:
                k, v = line[3:].split(":", 1)
                out[k.strip()] = v.strip()
    return out


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
    os.makedirs(out_dir, exist_ok=True)
    zip_path = os.path.join(out_dir, f"{name}-{version}.zip")
    files = collect(addon_dir)
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        for path in files:
            rel = os.path.relpath(path, addon_dir).replace(os.sep, "/")
            z.write(path, f"{name}/{rel}")
    return zip_path, version, files


def main(argv):
    p = argparse.ArgumentParser(prog="wowf package")
    p.add_argument("addon")
    p.add_argument("--skip-lint", action="store_true")
    a = p.parse_args(argv)
    cfg = config.load()
    root = cfg["_root"]
    addon_dir = a.addon if os.path.isabs(a.addon) else os.path.join(root, a.addon)
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
