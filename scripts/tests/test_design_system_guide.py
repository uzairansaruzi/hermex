"""Contract tests for `scripts/design-system-guide` — the deterministic, dependency-free lookup/
exact-select/decision-receipt CLI over the checked-in `design-system-catalog/hermex-manifest.json`.

Loaded as a module via importlib (the executable has no `.py` suffix) so these tests can exercise
its scoring/tokenizing functions directly, in addition to subprocess-level CLI/exit-code contracts.
"""
from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import unittest

REPO_ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", ".."))
GUIDE_PATH = os.path.join(REPO_ROOT, "scripts", "design-system-guide")
MANIFEST_PATH = os.path.join(REPO_ROOT, "design-system-catalog", "hermex-manifest.json")


def _load_guide_module():
    # The executable has no `.py` suffix, so spec_from_file_location can't infer a loader from the
    # extension alone — pass an explicit SourceFileLoader instead.
    loader = importlib.machinery.SourceFileLoader("design_system_guide", GUIDE_PATH)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def run_cli(args, expect_success=True):
    result = subprocess.run(
        [sys.executable, GUIDE_PATH, *args],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    if expect_success:
        assert result.returncode == 0, f"expected exit 0, got {result.returncode}\nstdout={result.stdout}\nstderr={result.stderr}"
    return result


class DesignSystemGuideFileTests(unittest.TestCase):
    def test_guide_executable_and_manifest_exist(self):
        self.assertTrue(os.path.exists(GUIDE_PATH), "expected scripts/design-system-guide to exist")
        self.assertTrue(os.access(GUIDE_PATH, os.X_OK), "expected scripts/design-system-guide to be executable")
        self.assertTrue(os.path.exists(MANIFEST_PATH), "expected the checked-in hermex-manifest.json to exist")


class DesignSystemGuideModuleTests(unittest.TestCase):
    def setUp(self):
        self.module = _load_guide_module()

    def test_tokenize_is_lowercase_and_alnum_only(self):
        self.assertEqual(self.module.tokenize("Mutually-Exclusive Selection!"), ["mutually", "exclusive", "selection"])

    def test_load_manifest_returns_schema_version_and_entries(self):
        manifest = self.module.load_manifest(MANIFEST_PATH)
        self.assertEqual(manifest["schemaVersion"], 1)
        self.assertEqual(len(manifest["entries"]), 37)

    def test_rank_entries_is_deterministic_and_score_ordered(self):
        manifest = self.module.load_manifest(MANIFEST_PATH)
        results_a = self.module.rank_entries(manifest, "exclusive selection")
        results_b = self.module.rank_entries(manifest, "exclusive selection")
        self.assertEqual([r["id"] for r in results_a], [r["id"] for r in results_b])
        scores = [r["score"] for r in results_a]
        self.assertTrue(all(isinstance(score, int) for score in scores))
        self.assertEqual(scores, sorted(scores, reverse=True))

    def test_representative_exclusive_selection_query_pins_hermes_radio_at_rank_one(self):
        manifest = self.module.load_manifest(MANIFEST_PATH)
        results = self.module.rank_entries(manifest, "exclusive selection")
        self.assertGreater(len(results), 0)
        self.assertEqual(results[0]["id"], "Hermes Radio")

    def test_find_exact_resolves_by_id_or_display_name(self):
        manifest = self.module.load_manifest(MANIFEST_PATH)
        by_id = self.module.find_exact(manifest, "Hermes Radio")
        by_display_name = self.module.find_exact(manifest, "Radio")
        self.assertIsNotNone(by_id)
        self.assertIsNotNone(by_display_name)
        self.assertEqual(by_id["id"], by_display_name["id"])

    def test_find_exact_returns_none_for_unknown_name(self):
        manifest = self.module.load_manifest(MANIFEST_PATH)
        self.assertIsNone(self.module.find_exact(manifest, "Not A Real Component"))


class DesignSystemGuideCliLookupTests(unittest.TestCase):
    def test_human_lookup_prints_ranked_results_with_a_reason(self):
        result = run_cli(["exclusive selection"])
        self.assertIn("Hermes Radio", result.stdout)
        self.assertIn("matched", result.stdout.lower())

    def test_json_lookup_is_valid_json_and_byte_stable(self):
        result_a = run_cli(["--json", "exclusive selection"])
        result_b = run_cli(["--json", "exclusive selection"])
        self.assertEqual(result_a.stdout, result_b.stdout)
        payload = json.loads(result_a.stdout)
        self.assertIsInstance(payload, list)
        self.assertEqual(payload[0]["id"], "Hermes Radio")

    def test_empty_query_fails_nonzero_with_clear_message(self):
        result = run_cli([""], expect_success=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(result.stderr.strip(), "expected a clear error message on stderr")

    def test_no_arguments_fails_nonzero_with_usage_message(self):
        result = run_cli([], expect_success=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("usage", (result.stderr + result.stdout).lower())


class DesignSystemGuideCliSelectTests(unittest.TestCase):
    def test_exact_select_human_mode(self):
        result = run_cli(["--select", "Hermes Radio"])
        self.assertIn("Hermes Radio", result.stdout)
        self.assertIn("foundation-available", result.stdout.lower())

    def test_exact_select_json_mode_contains_required_fields(self):
        result = run_cli(["--select", "Hermes Radio", "--json"])
        payload = json.loads(result.stdout)
        self.assertEqual(payload["id"], "Hermes Radio")
        self.assertIn("canonicalSymbols", payload)
        self.assertIn("adoptionStatus", payload)

    def test_unknown_select_fails_nonzero_with_clear_message(self):
        result = run_cli(["--select", "Not A Real Component"], expect_success=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not a real component", result.stderr.lower())


class DesignSystemGuideCliFailureTests(unittest.TestCase):
    def test_missing_manifest_fails_nonzero_with_clear_message(self):
        env = dict(os.environ)
        env["HERMEX_MANIFEST_PATH"] = os.path.join(REPO_ROOT, "design-system-catalog", "does-not-exist.json")
        result = subprocess.run(
            [sys.executable, GUIDE_PATH, "banner"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            env=env,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("manifest", result.stderr.lower())

    def test_unreadable_stale_schema_fails_nonzero_with_clear_message(self):
        import tempfile

        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
            json.dump({"schemaVersion": 999, "entries": []}, handle)
            stale_path = handle.name
        try:
            env = dict(os.environ)
            env["HERMEX_MANIFEST_PATH"] = stale_path
            result = subprocess.run(
                [sys.executable, GUIDE_PATH, "banner"],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("schema", result.stderr.lower())
        finally:
            os.unlink(stale_path)


class DesignSystemGuideReceiptTests(unittest.TestCase):
    VALID_RECEIPT_ARGS = [
        "receipt",
        "--query", "exclusive selection",
        "--select", "Hermes Radio",
        "--reject", "Segmented Control::Use for compact two-to-five option switching, not a longer form group.",
        "--new-component", "no",
        "--new-component-reason", "Hermes Radio already models one choice from a mutually exclusive group.",
    ]

    def test_valid_receipt_human_mode_succeeds_and_names_every_required_fact(self):
        result = run_cli(self.VALID_RECEIPT_ARGS)
        self.assertIn("Hermes Radio", result.stdout)
        self.assertIn("Segmented Control", result.stdout)
        self.assertIn("foundation-available", result.stdout.lower())

    def test_valid_receipt_json_mode_contains_every_required_field(self):
        result = run_cli([*self.VALID_RECEIPT_ARGS, "--json"])
        payload = json.loads(result.stdout)
        self.assertEqual(payload["query"], "exclusive selection")
        self.assertEqual(payload["selected"]["id"], "Hermes Radio")
        self.assertIn("adoptionStatus", payload["selected"])
        self.assertIn("canonicalSymbols", payload["selected"])
        self.assertIn("sourcePaths", payload["selected"])
        self.assertEqual(len(payload["rejectedAlternatives"]), 1)
        self.assertEqual(payload["rejectedAlternatives"][0]["name"], "Segmented Control")
        self.assertTrue(payload["rejectedAlternatives"][0]["reason"])
        self.assertEqual(payload["newComponentNeeded"], "no")
        self.assertTrue(payload["newComponentReason"])
        self.assertEqual(payload["manifestSchemaVersion"], 1)

    def test_receipt_requires_at_least_one_rejected_alternative(self):
        args = [
            "receipt", "--query", "q", "--select", "Hermes Radio",
            "--new-component", "no", "--new-component-reason", "because",
        ]
        result = run_cli(args, expect_success=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("reject", result.stderr.lower())

    def test_receipt_rejects_empty_reject_reason(self):
        args = [
            "receipt", "--query", "q", "--select", "Hermes Radio",
            "--reject", "Segmented Control::",
            "--new-component", "no", "--new-component-reason", "because",
        ]
        result = run_cli(args, expect_success=False)
        self.assertNotEqual(result.returncode, 0)

    def test_receipt_requires_valid_new_component_value(self):
        args = [
            "receipt", "--query", "q", "--select", "Hermes Radio",
            "--reject", "Segmented Control::reason",
            "--new-component", "maybe", "--new-component-reason", "because",
        ]
        result = run_cli(args, expect_success=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("yes", result.stderr.lower())

    def test_receipt_requires_new_component_reason(self):
        args = [
            "receipt", "--query", "q", "--select", "Hermes Radio",
            "--reject", "Segmented Control::reason",
            "--new-component", "no", "--new-component-reason", "",
        ]
        result = run_cli(args, expect_success=False)
        self.assertNotEqual(result.returncode, 0)

    def test_receipt_requires_known_select_target(self):
        args = [
            "receipt", "--query", "q", "--select", "Not A Real Component",
            "--reject", "Segmented Control::reason",
            "--new-component", "no", "--new-component-reason", "because",
        ]
        result = run_cli(args, expect_success=False)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
