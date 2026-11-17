"""Tests for Tools/build-dictionary.py and Tools/dictionary_release.py on a tiny ECDICT sample.

Run with: python3 -m unittest discover -s Tools/tests -v
"""

import csv
import hashlib
import json
import os
import shutil
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import dictionary_release as release  # noqa: E402

COLUMNS = ["word", "phonetic", "definition", "translation", "pos", "collins", "oxford", "tag", "bnc", "frq",
           "exchange", "detail", "audio"]
# word, translation, definition, tag, collins, bnc, exchange
ROWS = [
    ("be", "v. 是, 表示, 在\\n[计] 后端, 总线允许", "v have the quality of being\\nused with a predicate", "zk gk", 5, 2,
     "p:was/3:is/d:been/i:being"),
    ("was", "be的过去式", "", "", 0, 0, ""),
    ("go", "vi. 去, 走", "", "zk", 5, 30, "p:went/d:gone/i:going/3:goes"),
    ("went", "go的过去式", "", "", 0, 0, "0:go/1:p"),
    ("do", "v. 做", "", "zk", 5, 20, "p:did/d:done/i:doing/3:does"),
    ("doe", "n. 雌鹿", "", "", 0, 30000, "s:does"),
    ("does", "v. 做（do的第三人称单数形式）", "", "", 0, 0, "0:doe/1:s"),
    ("find", "vt. 发现", "", "zk", 5, 300, "p:found/d:found/i:finding/3:finds"),
    ("found", "vt. 建立, 创立\\nfind的过去式和过去分词", "", "cet4", 4, 2600, "0:find/1:dp/d:founded"),
    ("give", "vt. 给", "", "zk", 5, 100, "p:gave/d:given"),
    ("up", "adv. 向上", "", "zk", 5, 50, ""),
    ("give up", "放弃, 停止\\n[法] 放弃", "", "", 0, 0, ""),
    ("appendicitis", "[医] 阑尾炎", "", "", 0, 0, ""),
    ("abdominal", "a. 腹部的", "", "cet6", 1, 9000, ""),
    ("abdominal ileotomy", "[医] 腹部回肠切开术", "", "", 0, 0, ""),
    ("benzene", "[化] 苯\\n[医] 苯", "", "", 0, 0, ""),
    ("abalienate", "vt. 让渡", "", "", 0, 0, ""),
    ("Einstein", "n. 爱因斯坦", "", "", 0, 0, ""),
    ("alice", "n. 爱丽丝", "", "", 0, 40000, ""),
    ("ALICE", "abbr. 自动化语言", "", "", 0, 0, ""),
]


def write_csv(path):
    with open(path, "w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(COLUMNS)
        for word, translation, definition, tag, collins, bnc, exchange in ROWS:
            writer.writerow([word, "", definition, translation, "", collins or "", "", tag, bnc, 0, exchange, "", ""])


def rows(path, sql):
    db = sqlite3.connect(path)
    try:
        return db.execute(sql).fetchall()
    finally:
        db.close()


class BuildTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = Path(tempfile.mkdtemp())
        write_csv(cls.dir / "ecdict.csv")
        cls.counts = release.builder.build(str(cls.dir / "ecdict.csv"), str(cls.dir / "out"), set(release.builder.PACKS),
                                           "2026.11.18", "0" * 40, log=lambda _: None)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.dir)

    def keys(self, pack):
        return {key for (key,) in rows(self.dir / "out" / f"dictionary-{pack}.sqlite", "SELECT key FROM entry")}

    def test_every_entry_lands_in_its_pack(self):
        self.assertTrue({"be", "go", "found", "give up", "abdominal", "alice"} <= self.keys("core"))
        # "give up" has a [法] sense but a general one too; "abdominal ileotomy" is all medicine.
        self.assertNotIn("give up", self.keys("law"))
        self.assertEqual(self.keys("medicine"), {"appendicitis", "abdominal ileotomy", "benzene"})
        self.assertEqual(self.keys("chemistry"), {"benzene"})  # Labelled for two fields: in both.
        self.assertEqual(self.keys("extended"), {"abalienate"})
        self.assertEqual(self.keys("names"), {"einstein"})

    def test_inflections_redirect_to_the_right_base(self):
        forms = dict(rows(self.dir / "out" / "dictionary-core.sqlite", "SELECT form, lemma FROM form"))
        self.assertEqual(forms["went"], "go")
        self.assertEqual(forms["was"], "be")  # Hand-listed: ECDICT gives "was" no base.
        self.assertEqual(forms["does"], "do")  # The more frequent base, not "doe".
        self.assertEqual(forms["found"], "find")
        self.assertEqual(forms["gave"], "give")
        for pack in release.builder.PACKS:
            if pack != "core":
                tables = rows(self.dir / "out" / f"dictionary-{pack}.sqlite",
                              "SELECT name FROM sqlite_master WHERE name = 'form'")
                self.assertEqual(tables, [], pack)

    def test_lowercase_spelling_wins_and_english_senses_are_joined(self):
        (word, translation), = rows(self.dir / "out" / "dictionary-core.sqlite",
                                    "SELECT word, translation FROM entry WHERE key = 'alice'")
        self.assertEqual((word, translation), ("alice", "n. 爱丽丝"))
        (definition,), = rows(self.dir / "out" / "dictionary-core.sqlite", "SELECT definition FROM entry WHERE key = 'be'")
        self.assertEqual(definition, "v. have the quality of being used with a predicate")

    def test_packs_record_version_source_and_group(self):
        meta = release.pack_meta(self.dir / "out" / "dictionary-medicine.sqlite")
        self.assertEqual((meta["version"], meta["sourceCommit"], meta["group"]), ("2026.11.18", "0" * 40, "field"))
        self.assertEqual(int(meta["entries"]), self.counts["medicine"])


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        # Template mode, whatever RELEASE_AI_* the shell has set.
        self.env = mock.patch.dict(os.environ, {"RELEASE_AI_PROVIDER": "none"})
        self.env.start()
        self.addCleanup(self.env.stop)
        csv_path = self.root / release.SOURCE_CSV
        csv_path.parent.mkdir(parents=True)
        write_csv(csv_path)
        self.source = {"name": "ECDICT", "commit": "a" * 40, "url": release.source_url("a" * 40),
                       "sha256": release.sha256_file(csv_path)}
        (self.root / release.RELEASE).parent.mkdir(parents=True)
        (self.root / release.RELEASE).write_text(json.dumps({"version": "2026.11.01", "source": self.source}))
        (self.root / release.CORE).parent.mkdir(parents=True)

    def tearDown(self):
        shutil.rmtree(self.root)

    def test_prepare_updates_core_and_drafts_notes_that_block_the_release(self):
        with self.assertRaises(ValueError):
            release.prepare(self.root, "2026.11.01")  # Not newer.
        release.prepare(self.root, "dict-2026.11.18")
        self.assertEqual(json.loads((self.root / release.RELEASE).read_text())["version"], "2026.11.18")
        self.assertEqual(release.pack_meta(self.root / release.CORE)["version"], "2026.11.18")
        self.assertEqual(release.check(self.root, "dict-2026.11.18"), "2026.11.18")
        with self.assertRaisesRegex(ValueError, "RELEASE_TODO"):
            release.check(self.root, require_notes=True)
        with self.assertRaisesRegex(ValueError, "不一致"):
            release.check(self.root, "dict-2026.11.19")

        notes = release.notes_path(self.root, "2026.11.18")
        text = notes.read_text().replace(next(line for line in notes.read_text().splitlines() if "RELEASE_TODO" in line),
                                          "- 首批词典包。")
        notes.write_text(text)
        release.check(self.root, require_notes=True)
        with self.assertRaisesRegex(ValueError, "高于"):
            release.prepare(self.root, "2026.11.18")  # The same release is never prepared twice.

    def test_build_is_reproducible_and_verifies_the_bundled_core(self):
        release.prepare(self.root, "2026.11.18")
        first = (self.root / release.BUILD / "SHA256SUMS").read_text()
        manifest = release.build(self.root, verify_core=True)
        self.assertEqual((self.root / release.BUILD / "SHA256SUMS").read_text(), first)
        self.assertEqual([pack["id"] for pack in manifest["packs"]][0], "extended")
        self.assertNotIn("core", [pack["id"] for pack in manifest["packs"]])
        for pack in manifest["packs"]:
            archive = self.root / release.BUILD / f"dictionary-{pack['id']}.zip"
            self.assertEqual(hashlib.sha256(archive.read_bytes()).hexdigest(), pack["sha256"])
            self.assertEqual(pack["url"], release.release_url("2026.11.18", archive.name))

        # A core edited by hand no longer matches what the pinned source builds.
        db = sqlite3.connect(self.root / release.CORE)
        db.execute("UPDATE entry SET translation = 'x' WHERE key = 'go'")
        db.commit()
        db.close()
        with self.assertRaisesRegex(ValueError, "不一致"):
            release.build(self.root, verify_core=True)

    def test_check_rejects_a_manifest_that_does_not_match_its_release(self):
        release.prepare(self.root, "2026.11.18")
        manifest = json.loads((self.root / release.BUILD / "manifest.json").read_text())
        (self.root / release.MANIFEST).write_text(json.dumps(manifest))
        release.check(self.root)
        manifest["packs"][0]["url"] = "https://example.com/dictionary-extended.zip"
        (self.root / release.MANIFEST).write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, "extended"):
            release.check(self.root)

    def test_versions_and_tags(self):
        self.assertEqual(release.normalize_version("dict-2026.11.18.2"), "2026.11.18.2")
        self.assertGreater(release.version_key("2026.11.18.10"), release.version_key("2026.11.18.9"))
        self.assertGreater(release.version_key("2026.11.18.1"), release.version_key("2026.11.18"))
        for bad in ("v2026.11.18", "2026-11-18", "2026.11.18.0", "26.11.18"):
            with self.assertRaises(ValueError):
                release.normalize_version(bad)


if __name__ == "__main__":
    unittest.main()
