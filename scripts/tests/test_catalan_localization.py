import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import catalan_localization as localization


def entry(key="Hello", source="Hello", target="TARGET", **extra):
    item = {
        "id": f"Localizable::{key}",
        "catalog": "Localizable",
        "key": key,
        "units": [{"source": source}],
        "sourceStructure": None,
        "placeholders": [],
        "protectedTerms": [],
        "comment": None,
        "surface": "main-app",
        "sourceReferences": [],
        "target": target,
    }
    item.update(extra)
    return item


def document(entries, catalog="Localizable"):
    return {
        "schemaVersion": 1,
        "sourceLanguage": "en",
        "targetLanguage": "ca",
        "catalog": catalog,
        "entries": entries,
    }


class CatalanLocalizationTests(unittest.TestCase):
    def test_valid_document_pair(self):
        source = document([entry(target=None)])
        returned = document([entry(target="TARGET")])
        self.assertEqual(localization.validate_document_pair(source, returned), [])

    def test_missing_target(self):
        source = document([entry(target=None)])
        returned = document([entry(target=" ")])
        errors = localization.validate_document_pair(source, returned)
        self.assertTrue(any("empty target" in error for error in errors))

    def test_duplicate_ids(self):
        source = document([entry(target=None), entry(target=None)])
        returned = document([entry(target="TARGET"), entry(target="TARGET")])
        errors = localization.validate_document_pair(source, returned)
        self.assertTrue(any("duplicate ID" in error for error in errors))

    def test_source_tampering_is_rejected(self):
        source = document([entry(target=None)])
        changed = entry(target="TARGET")
        changed["key"] = "Changed"
        errors = localization.validate_document_pair(source, document([changed]))
        self.assertTrue(any("source or metadata changed" in error for error in errors))

    def test_placeholder_loss_and_multiplicity_are_rejected(self):
        source_entry = entry(
            key="%@ %lld",
            source="%@ %lld",
            target=None,
            placeholders=["%@", "%lld"],
        )
        source = document([source_entry])
        for bad in ("Text %@", "Text %@ %@", "Text %@ %d"):
            returned_entry = copy.deepcopy(source_entry)
            returned_entry["target"] = bad
            returned = document([returned_entry])
            errors = localization.validate_document_pair(source, returned)
            self.assertTrue(any("placeholder mismatch" in error for error in errors), bad)

    def test_missing_plural_branch_is_rejected(self):
        source_item = entry(key="%lld cats", source="%lld cats", target=None)
        source_item["units"] = [
            {"variation": "plural", "case": "one", "source": "%lld cat"},
            {"variation": "plural", "case": "other", "source": "%lld cats"},
        ]
        source_item["sourceStructure"] = {"variations": {"plural": ["one", "other"]}}
        returned_item = copy.deepcopy(source_item)
        returned_item["target"] = {"other": "TARGET %lld"}
        errors = localization.validate_document_pair(
            document([source_item]), document([returned_item])
        )
        self.assertTrue(any("plural cases" in error for error in errors))

    def test_plural_placeholders_are_checked_per_branch(self):
        source_item = entry(key="%lld cats", source="%lld cats", target=None)
        source_item["units"] = [
            {"variation": "plural", "case": "one", "source": "%lld cat"},
            {"variation": "plural", "case": "other", "source": "%lld cats"},
        ]
        source_item["sourceStructure"] = {"variations": {"plural": ["one", "other"]}}
        returned_item = copy.deepcopy(source_item)
        returned_item["target"] = {"one": "TARGET", "other": "TARGET %lld %lld"}
        errors = localization.validate_document_pair(
            document([source_item]), document([returned_item])
        )
        self.assertTrue(any("branch one placeholder mismatch" in error for error in errors))

    def test_malformed_json_rejects_package(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "source").mkdir()
            (root / "returned").mkdir()
            (root / "manifest.json").write_text(json.dumps({
                "batches": [{"file": "Localizable-001.json"}],
                "catalogs": {"Localizable": {"entryCount": 1}},
            }))
            (root / "source" / "Localizable-001.json").write_text("{")
            (root / "returned" / "Localizable-001.json").write_text("{}")
            with self.assertRaises(localization.PackageError) as raised:
                localization.validate_package(root)
            self.assertIn("malformed JSON", str(raised.exception))

    def test_stale_source_rejects_package(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = root / "package"
            repo = root / "repo"
            (package / "source").mkdir(parents=True)
            (package / "returned").mkdir(parents=True)
            repo.mkdir()
            (repo / "Strings.xcstrings").write_text("original")
            source = document([entry(target=None)])
            returned = document([entry(target="TARGET")])
            (package / "source" / "Localizable-001.json").write_text(json.dumps(source))
            (package / "returned" / "Localizable-001.json").write_text(json.dumps(returned))
            digest = localization.hashlib.sha256(b"different").hexdigest()
            (package / "manifest.json").write_text(json.dumps({
                "sourceRevision": "abc",
                "sourceFiles": [{"path": "Strings.xcstrings", "sha256": digest}],
                "batches": [{"file": "Localizable-001.json"}],
                "catalogs": {"Localizable": {"entryCount": 1}},
            }))
            with mock.patch.object(localization.subprocess, "check_output", return_value="abc\n"):
                with self.assertRaises(localization.PackageError) as raised:
                    localization.validate_package(package, repo, check_source_hashes=True)
            self.assertIn("Source changed since extraction", str(raised.exception))

    def test_invalid_package_cannot_write_any_catalog(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = root / "package"
            repo = root / "repo"
            (package / "source").mkdir(parents=True)
            (package / "returned").mkdir(parents=True)
            (repo / "HermesMobile" / "Resources").mkdir(parents=True)
            catalog = repo / "HermesMobile" / "Resources" / "Localizable.xcstrings"
            catalog.write_text("sentinel")
            source = document([entry(target=None)])
            returned = document([entry(target="TARGET"), entry(target="TARGET")])
            (package / "source" / "Localizable-001.json").write_text(json.dumps(source))
            (package / "returned" / "Localizable-001.json").write_text(json.dumps(returned))
            (package / "manifest.json").write_text(json.dumps({
                "sourceRevision": "abc",
                "batches": [{"file": "Localizable-001.json"}],
                "catalogs": {"Localizable": {"entryCount": 1}},
            }))
            with mock.patch.object(localization.subprocess, "check_output", return_value="abc\n"):
                with mock.patch.object(localization, "_atomic_write") as atomic_write:
                    with self.assertRaises(localization.PackageError):
                        localization.import_package(package, repo)
            atomic_write.assert_not_called()
            self.assertEqual(catalog.read_text(), "sentinel")

    def test_validation_allows_package_based_on_an_earlier_commit(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = root / "package"
            repo = root / "repo"
            (package / "source").mkdir(parents=True)
            (package / "returned").mkdir(parents=True)
            repo.mkdir()
            source = document([entry(target=None)])
            returned = document([entry(target="TARGET")])
            (package / "source" / "Localizable-001.json").write_text(json.dumps(source))
            (package / "returned" / "Localizable-001.json").write_text(json.dumps(returned))
            (package / "manifest.json").write_text(json.dumps({
                "sourceRevision": "base",
                "batches": [{"file": "Localizable-001.json"}],
                "catalogs": {"Localizable": {"entryCount": 1}},
            }))
            with mock.patch.object(localization.subprocess, "check_output", return_value="package-commit\n"):
                manifest = localization.validate_package(package, repo)
            self.assertEqual(manifest["sourceRevision"], "base")

    def test_import_preserves_existing_language_bytes_and_semantics(self):
        catalog_text = json.dumps({
            "sourceLanguage": "en",
            "strings": {
                "Hello": {
                    "localizations": {
                        "en": {"stringUnit": {"state": "translated", "value": "Hello"}},
                        "de": {"stringUnit": {"state": "needs_review", "value": "Hallo"}},
                    }
                }
            },
            "version": "1.0",
        })
        translated = entry(target="TARGET")
        updated = localization.add_language_to_catalog(catalog_text, [translated])
        parsed = json.loads(updated)
        localization_value = parsed["strings"]["Hello"]["localizations"]["ca"]["stringUnit"]["value"]
        self.assertEqual(localization_value, "TARGET")
        self.assertEqual(parsed["strings"]["Hello"]["localizations"]["de"]["stringUnit"]["value"], "Hallo")


if __name__ == "__main__":
    unittest.main()
