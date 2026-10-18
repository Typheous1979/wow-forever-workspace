import os
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import config  # noqa: E402
import index as idx  # noqa: E402
import luacheckrc  # noqa: E402


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def build(files):
    """build_framexml over a fake Blizzard UI source: {"Addon/File.xml": text}."""
    with tempfile.TemporaryDirectory() as d:
        for rel, text in files.items():
            write(os.path.join(d, "Interface", "AddOns", *rel.split("/")), text)
        with mock.patch.object(config, "UPSTREAM_DIR", d):
            recs = idx.build_framexml(log=lambda *_: None)
    return {(r["k"], r["id"]): r for r in recs}


SHARED = {
    "Blizzard_Shared/Blizzard_Shared.toc": "## Title: Shared\nTemplates.xml\n",
    "Blizzard_Shared/Templates.xml": """<Ui>
  <EditBox name="WowfTestSearchTemplate" mixin="WowfTestSearchMixin" inherits="InputBoxTemplate" virtual="true">
    <Layers><Layer level="OVERLAY"><Texture name="$parentIcon" parentKey="searchIcon"/></Layer></Layers>
  </EditBox>
  <Frame name="WowfTestNamedFrame"/>
  <Font name="WowfTestFont" inherits="GameFontNormal" virtual="true"/>
  <Texture name="WowfTestTextureTemplate" virtual="true"/>
</Ui>
""",
}


class TemplateIndex(unittest.TestCase):
    def test_virtual_elements_are_templates_not_globals(self):
        recs = build(SHARED)
        self.assertEqual(recs[("tpl", "WowfTestSearchTemplate")], {
            "k": "tpl", "id": "WowfTestSearchTemplate", "type": "EditBox", "a": "Blizzard_Shared",
            "file": "Blizzard_Shared/Templates.xml", "mixin": "WowfTestSearchMixin", "inherits": "InputBoxTemplate"})
        self.assertNotIn(("fx", "WowfTestSearchTemplate"), recs)
        self.assertIn(("fx", "WowfTestNamedFrame"), recs)        # a named frame is still a global
        self.assertNotIn(("tpl", "WowfTestNamedFrame"), recs)

    def test_load_on_demand_classic_folders_and_game_types(self):
        recs = build({
            "Blizzard_Lod/Blizzard_Lod.toc": "## LoadOnDemand: 1\nLod.xml\n",
            "Blizzard_Lod/Lod.xml": '<Ui><Button name="WowfLodTemplate" virtual="true"/></Ui>',
            "Blizzard_Mixed/Blizzard_Mixed.toc": "Mainline\\Mixed.xml\n",
            "Blizzard_Mixed/Classic/Mixed.xml": '<Ui><Frame name="WowfDupTemplate" inherits="Old" virtual="true"/>'
                                                '<Frame name="WowfClassicOnlyTemplate" virtual="true"/></Ui>',
            "Blizzard_Mixed/Mainline/Mixed.xml": '<Ui><Frame name="WowfDupTemplate" inherits="New" virtual="true"/></Ui>',
            "Blizzard_Glue/Blizzard_Glue.toc": "## AllowLoadGameType: standard\nGlue.xml\n",
            "Blizzard_Glue/Glue.xml": '<Ui><Frame name="WowfGlueTemplate" virtual="true"/></Ui>',
        })
        self.assertTrue(recs[("tpl", "WowfLodTemplate")]["lod"])
        self.assertTrue(recs[("addon", "Blizzard_Lod")]["lod"])
        self.assertNotIn("lod", recs[("addon", "Blizzard_Mixed")])
        dup = recs[("tpl", "WowfDupTemplate")]
        self.assertEqual((dup["inherits"], dup["file"]), ("New", "Blizzard_Mixed/Mainline/Mixed.xml"))  # Forever's wins
        self.assertNotIn("forever", dup)
        self.assertIs(recs[("tpl", "WowfClassicOnlyTemplate")]["forever"], False)   # Classic folder, not in the TOC
        self.assertIs(recs[("tpl", "WowfGlueTemplate")]["forever"], False)          # the addon doesn't load on Forever

    def test_lookup_and_find_but_never_a_lint_global(self):
        recs = build(SHARED)
        with tempfile.TemporaryDirectory() as root:
            idx.write_jsonl(os.path.join(idx.data_dir(root), "framexml.jsonl"), {"k": "meta", "layer": "framexml"},
                            list(recs.values()))
            I = idx.Index(root)
            self.assertEqual([r["k"] for r in I.lookup("WowfTestSearchTemplate")], ["tpl"])
            self.assertIn("WowfTestSearchTemplate", [r["id"] for r in I.find("^WowfTest", {"tpl"})])
            self.assertNotIn("WowfTestSearchTemplate", [r["id"] for r in I.find("^WowfTest", {"fx"})])
            self.assertEqual(I.known_function("WowfTestSearchTemplate"), set())
            rc = luacheckrc.generate(root, I)
            self.assertNotIn('"WowfTestSearchTemplate"', rc)
            self.assertIn('"WowfTestNamedFrame"', rc)

    def test_format_record_says_how_to_use_it(self):
        recs = build(SHARED)
        text = idx.format_record(recs[("tpl", "WowfTestSearchTemplate")])
        self.assertIn("XML template WowfTestSearchTemplate  (EditBox; Blizzard_Shared; loads on Forever)", text)
        self.assertIn("inherits InputBoxTemplate; mixin WowfTestSearchMixin", text)
        self.assertIn('CreateFrame("EditBox", nil, parent, "WowfTestSearchTemplate"); a template is not a global', text)
        self.assertIn('CreateTexture(nil, "ARTWORK", "WowfTestTextureTemplate")',
                      idx.format_record(recs[("tpl", "WowfTestTextureTemplate")]))
        self.assertIn("SetFontObject(WowfTestFont); a font object is also a global",
                      idx.format_record(recs[("tpl", "WowfTestFont")]))
        lod = idx.format_record({"k": "tpl", "id": "XTemplate", "type": "Button", "a": "Blizzard_X", "lod": True})
        self.assertIn("(Button; Blizzard_X, load on demand; loads on Forever)", lod)
        self.assertIn("exists once Blizzard_X has loaded", lod)


if __name__ == "__main__":
    unittest.main()
