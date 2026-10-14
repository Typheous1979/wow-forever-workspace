import os
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import music_catalog as mc  # noqa: E402


def id3_tag(frames):
    body = b""
    for fid, text in frames.items():
        payload = b"\x03" + text.encode("utf-8")
        body += fid.encode() + struct.pack(">I", len(payload)) + b"\0\0" + payload
    size = len(body)
    syncsafe = bytes([(size >> 21) & 127, (size >> 14) & 127, (size >> 7) & 127, size & 127])
    return b"ID3\x03\x00\x00" + syncsafe + body


def xing_frame(frames):
    # MPEG1 layer III, 128 kbps, 44.1 kHz, stereo: side info 32 bytes
    header = bytes([0xFF, 0xFB, 0x90, 0x64])
    xing = b"Xing" + struct.pack(">I", 1) + struct.pack(">I", frames)
    return header + b"\0" * 32 + xing + b"\0" * 300


class AudioParsing(unittest.TestCase):
    def test_id3_and_xing_length(self):
        data = id3_tag({"TIT2": "Day Forest 01", "TALB": "C60"}) + xing_frame(2000)
        info = mc.describe_audio(data, complete=False)
        self.assertEqual(info["title"], "Day Forest 01")
        self.assertEqual(info["album"], "C60")
        self.assertAlmostEqual(info["seconds"], round(2000 * 1152 / 44100, 1))

    def test_cbr_needs_total_length(self):
        frame = bytes([0xFF, 0xFB, 0x90, 0x64]) + b"\0" * 400   # no Xing header
        self.assertIsNone(mc.mp3_seconds(frame, 0, None))
        secs = mc.mp3_seconds(frame, 0, 16000)
        self.assertAlmostEqual(secs, 16000 * 8 / 128000)

    def test_ogg_length(self):
        ident = b"\x01vorbis" + struct.pack("<I", 0) + b"\x02" + struct.pack("<I", 48000)
        first = b"OggS" + b"\0" * 22 + ident
        last = b"OggS\0\x04" + struct.pack("<q", 48000 * 90) + b"\0" * 20
        self.assertAlmostEqual(mc.ogg_seconds(first + b"\0" * 100 + last), 90.0)


class Naming(unittest.TestCase):
    def test_track_name(self):
        self.assertEqual(mc.track_name({"title": "Day Forest 01", "file": "mus_c_day_forest_2.mp3"}, 1), "Day Forest 01")
        self.assertEqual(mc.track_name({"title": "stormwind05-zone", "file": "stormwind05-zone.mp3"}, 1), "Stormwind 05 Zone")
        self.assertEqual(mc.track_name({"file": "darnassus walking 1.mp3"}, 1), "Darnassus Walking 1")
        self.assertEqual(mc.track_name({}, 42), "Track 42")
        self.assertEqual(mc.pretty_file_name("mus_c_zalazanes_fall_4.mp3"), "Zalazanes Fall 4")
        self.assertEqual(mc.pretty_file_name("1.15.7 - raid - scarlet enclave - chapel - walk 1_6861013.mp3"),
                         "Scarlet Enclave Chapel Walk 1")
        self.assertEqual(mc.pretty_file_name("daybarrendry03.mp3"), "Day Barren Dry 03")
        self.assertEqual(mc.pretty_file_name("AQTriangle5.mp3"), "AQ Triangle 5")
        self.assertEqual(mc.pretty_file_name("mus_100_thaldraszus_3_h.mp3"), "Thaldraszus 3 H")

    def test_set_names(self):
        self.assertEqual(mc.set_kind("1.60 Dungeon - Dalaran City"), "Dungeon")
        self.assertEqual(mc.set_kind("Zone-Forest"), "Zone")
        self.assertEqual(mc.set_kind("Moment-Battle02"), "Moment")
        self.assertEqual(mc.pretty_set_name("1.60 Dungeon - Dalaran City Sewer"), "Dalaran City Sewer")
        self.assertEqual(mc.pretty_set_name("Zone-CursedLandFelwood"), "Cursed Land Felwood")


CSV = {
    "AreaTable": "ID,AreaName_lang,ContinentID,ParentAreaID,ZoneMusic,IntroSound,Flags_0\n"
                 "12,Elwynn Forest,0,0,1,0,64\n"
                 "87,Goldshire,0,12,1,0,64\n"
                 "88,Jerod's Landing,0,12,2,0,64\n"
                 "89,Zone UNUSED,0,12,2,0,64\n"
                 "1519,Stormwind City,0,0,3,61,312\n"
                 "500,Deadmines,36,0,2,0,0\n",
    "WMOAreaTable": "ID,AreaName_lang,AreaTableID,ZoneMusic,IntroSound\n"
                    "7,The Slaughtered Lamb,1519,2,0\n",
    "ZoneMusic": "ID,SetName,Sounds_0,Sounds_1\n1,Zone-Forest,100,101\n2,Moment-Mystery,102,102\n3,Zone-Stormwind,103,103\n",
    "SoundKitEntry": "ID,SoundKitID,FileDataID\n1,100,9001\n2,100,9002\n3,101,9003\n4,102,9004\n5,103,9005\n6,104,9006\n7,105,9007\n",
    "SoundKit": "ID,SoundType\n100,28\n101,28\n102,28\n103,28\n104,28\n105,28\n",
    "ZoneIntroMusicTable": "ID,Name,SoundID\n61,Valley of Heroes,104\n",
    "Map": "ID,MapName_lang,InstanceType\n0,Eastern Kingdoms,0\n36,Deadmines,1\n13,Test Dungeon,1\n",
}


class Hierarchy(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.old = mc.MUSIC_DIR
        mc.MUSIC_DIR = self.tmp.name
        d = mc.csv_dir("test")
        os.makedirs(d)
        for name, text in CSV.items():
            with open(os.path.join(d, name + ".csv"), "w", encoding="utf-8", newline="") as f:
                f.write(text)

    def tearDown(self):
        mc.MUSIC_DIR = self.old
        self.tmp.cleanup()

    def find(self, root, name):
        for n in mc._walk(root):
            if n["name"] == name:
                return n
        return None

    def test_tree(self):
        root = mc.build_tree(mc.Data("test"))
        tops = [c["name"] for c in root["children"]]
        self.assertEqual(tops, ["Zones", "Cities", "Dungeons", "Music Sets", "Other Music"])
        elwynn = self.find(root, "Elwynn Forest")
        self.assertEqual([c["name"] for c in elwynn["children"]], ["Day", "Night", "Jerod's Landing"])
        self.assertEqual(self.find(elwynn, "Day")["tracks"], [9001, 9002])
        self.assertIsNone(self.find(root, "Goldshire"), "same music as its parent: no own folder")
        self.assertIsNone(self.find(root, "Zone UNUSED"))
        city = self.find(root, "Stormwind City")
        self.assertEqual([c["name"] for c in city["children"]], ["Music", "Intro", "The Slaughtered Lamb"])
        self.assertIsNone(self.find(root, "Test Dungeon"))
        self.assertEqual(self.find(root, "Other Music")["tracks"], [9007])

    def test_lua_output(self):
        root = mc.build_tree(mc.Data("test"))
        meta = {str(i): {"title": f"Song {i}", "file": f"mus_{i}.mp3", "seconds": 60.5} for i in range(9001, 9008)}
        text, n = mc.emit_lua(root, meta, "test", {9001}, "2026-10-14")
        self.assertEqual(n, 7)
        self.assertTrue(text.startswith("local addonName, ns = ...\n"))
        self.assertIn('T[9001] = {"Song 9001", 60.5, 0}', text)   # in live retail
        self.assertIn('T[9002] = {"Song 9002", 60.5, 1}', text)   # Forever only
        self.assertIn('{"Day", nil, {9001, 9002}},', text)


if __name__ == "__main__":
    unittest.main()
