import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import validate_skills  # noqa: E402

SKILLS = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(HERE))), ".claude", "skills")


class SkillTests(unittest.TestCase):
    """Every workspace skill passes validate_skills.py (frontmatter, size, referenced files)."""

    def test_all_skills_valid(self):
        dirs = [os.path.join(SKILLS, d) for d in sorted(os.listdir(SKILLS)) if os.path.isdir(os.path.join(SKILLS, d))]
        self.assertGreaterEqual(len(dirs), 7)
        errors = [e for d in dirs for e in validate_skills.check(d)]
        self.assertEqual(errors, [])

    def test_frontmatter_values_are_single_line(self):
        # validate_skills parses one `key: value` per line; a YAML block scalar would silently truncate
        for d in sorted(os.listdir(SKILLS)):
            path = os.path.join(SKILLS, d, "SKILL.md")
            if not os.path.isfile(path):
                continue
            with open(path, encoding="utf-8") as f:
                fm, _ = validate_skills.parse_frontmatter(f.read())
            self.assertIsNotNone(fm, d)
            for key, value in fm.items():
                self.assertNotIn(value, ("|", ">", "|-", ">-"), f"{d}: {key} uses a YAML block scalar")


if __name__ == "__main__":
    unittest.main()
