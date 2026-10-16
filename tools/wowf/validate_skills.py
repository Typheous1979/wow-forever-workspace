"""Validate .claude/skills/*/SKILL.md (stdlib only).

  python tools/wowf/validate_skills.py

Checks: frontmatter present; name kebab-case <=64 and equal to folder; description present,
<=1024 chars, no angle brackets; known Claude Code keys only; body < 500 lines;
referenced references/*.md and scripts/*.py files exist.
"""
import os
import re
import sys

KNOWN = {"name", "description", "when_to_use", "argument-hint", "arguments", "disable-model-invocation", "user-invocable",
         "allowed-tools", "disallowed-tools", "model", "effort", "context", "agent", "background", "hooks", "paths",
         "shell", "metadata", "license", "compatibility"}


def parse_frontmatter(text):
    if not text.startswith("---"):
        return None, text
    end = text.find("\n---", 3)
    if end < 0:
        return None, text
    fm = {}
    for line in text[3:end].strip().splitlines():
        m = re.match(r"^([A-Za-z_-]+):\s*(.*)$", line)
        if m:
            v = m.group(2).strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                v = v[1:-1]
            fm[m.group(1)] = v
    return fm, text[end + 4:]


def check(skill_dir):
    errs = []
    name = os.path.basename(skill_dir)
    path = os.path.join(skill_dir, "SKILL.md")
    if not os.path.isfile(path):
        return [f"{name}: SKILL.md missing"]
    with open(path, encoding="utf-8") as f:
        text = f.read()
    fm, body = parse_frontmatter(text)
    if fm is None:
        return [f"{name}: no frontmatter"]
    for k in fm:
        if k not in KNOWN:
            errs.append(f"{name}: unknown frontmatter key {k}")
    if fm.get("name") != name:
        errs.append(f"{name}: name '{fm.get('name')}' != folder")
    if not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", fm.get("name", "")) or len(fm.get("name", "")) > 64:
        errs.append(f"{name}: name not kebab-case <=64")
    d = fm.get("description", "")
    if not d:
        errs.append(f"{name}: description missing")
    if len(d) > 1024:
        errs.append(f"{name}: description {len(d)} chars > 1024")
    if "<" in d or ">" in d:
        errs.append(f"{name}: description has angle brackets")
    if len(d) + len(fm.get("when_to_use", "")) > 1536:
        errs.append(f"{name}: description+when_to_use > 1536")
    n = body.count("\n")
    if n >= 500:
        errs.append(f"{name}: body {n} lines >= 500")
    for ref in set(re.findall(r"`((?:references|scripts|assets)/[A-Za-z0-9_./-]+)`", body)):
        if not os.path.exists(os.path.join(skill_dir, ref)):
            errs.append(f"{name}: referenced {ref} missing")
    return errs


def main():
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    sk = os.path.join(root, ".claude", "skills")
    all_errs = []
    for d in sorted(os.listdir(sk)):
        p = os.path.join(sk, d)
        if os.path.isdir(p):
            e = check(p)
            all_errs += e
            print(f"{'OK  ' if not e else 'FAIL'} {d}")
    for e in all_errs:
        print("  " + e)
    return 1 if all_errs else 0


if __name__ == "__main__":
    sys.exit(main())
