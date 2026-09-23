import json
import subprocess
import sys
import tempfile
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parent / "check_string_catalog.py"
TARGETS = ("HermesMobile", "HermesLiveActivityWidget", "HermesNotificationService")


class CheckStringCatalogTests(unittest.TestCase):
    """Runs the script the way CI does, against a fake DerivedData and catalog."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.source = self.root / "View.swift"
        self.source.write_text("// source\n")

    def tearDown(self):
        self.directory.cleanup()

    def stringsdata(self, target, keys, source=None, arch="arm64", table="Localizable"):
        folder = (self.root / "dd" / "Build" / "Intermediates.noindex" / "HermesMobile.build"
                  / "Debug-iphonesimulator" / f"{target}.build" / "Objects-normal" / arch)
        folder.mkdir(parents=True, exist_ok=True)
        entries = [{"key": key, "location": {"startingLine": line}} for key, line in keys]
        path = folder / f"{(source or self.source).stem}.stringsdata"
        # One file per source holds every table that source uses, like the compiler's output.
        data = json.loads(path.read_text()) if path.exists() else {"source": str(source or self.source), "tables": {}}
        data["tables"].setdefault(table, []).extend(entries)
        path.write_text(json.dumps(data))

    def every_target(self, keys):
        for target in TARGETS:
            self.stringsdata(target, keys)

    def run_check(self, catalog_keys):
        catalog = self.root / "Localizable.xcstrings"
        catalog.write_text(json.dumps({"strings": {key: {} for key in catalog_keys}}))
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--derived-data", str(self.root / "dd"), "--catalog", str(catalog)],
            capture_output=True, text=True, env={"PATH": "/usr/bin:/bin"},
        )

    def test_passes_when_catalog_covers_every_key_including_extra_stale_ones(self):
        self.every_target([("Send", 3)])
        self.stringsdata("HermesMobile", [("Send", 3)], arch="x86_64")
        result = self.run_check(["Send", "Old stale key"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("covers all 1 extracted keys", result.stdout)

    def test_missing_key_fails_and_names_source_line_and_targets(self):
        self.every_target([("Send", 3), ("Retry %@", 9)])
        result = self.run_check(["Send"])
        self.assertEqual(result.returncode, 1)
        self.assertIn('"Retry %@"', result.stdout)
        self.assertIn("View.swift:9", result.stdout)
        self.assertIn("HermesLiveActivityWidget, HermesMobile, HermesNotificationService", result.stdout)

    def test_ignores_other_tables_and_sources_deleted_since_the_build(self):
        self.every_target([("Send", 3)])
        self.stringsdata("HermesMobile", [("Shortcut phrase", 1)], table="AppShortcuts")
        self.stringsdata("HermesMobile", [("Gone", 2)], source=self.root / "Deleted.swift")
        result = self.run_check(["Send"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        # The mixed-table file still contributes its Localizable key.
        self.assertEqual(self.run_check([]).returncode, 1)

    def test_missing_target_output_is_an_error_not_a_pass(self):
        self.stringsdata("HermesMobile", [("Send", 3)])
        result = self.run_check(["Send"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no .stringsdata files for HermesLiveActivityWidget", result.stderr)


if __name__ == "__main__":
    unittest.main()
