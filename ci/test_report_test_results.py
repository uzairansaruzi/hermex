import subprocess
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch

import report_test_results as report


class ReportTests(unittest.TestCase):
    def test_build_failure_without_bundle_shows_compiler_error_and_phase(self):
        with tempfile.TemporaryDirectory() as directory:
            logs = Path(directory)
            (logs / "build.log").write_text("Compiling\nView.swift:12: error: cannot type-check\n")
            text = report.render({"BUILD_OUTCOME": "failure", "TEST_OUTCOME": "skipped"}, logs)
        self.assertIn("Failed or interrupted phase: Build for testing", text)
        self.assertIn("View.swift:12: error: cannot type-check", text)
        self.assertIn("Test summary unavailable", text)

    def test_assertion_failure_preserves_name_and_message(self):
        summary = {"passedTests": 3, "failedTests": 1, "skippedTests": 2,
                   "testFailures": [{"testName": "RoomTests.testCachedSearch()",
                                     "failureText": "XCTAssertEqual failed: expected cached room"}]}
        with tempfile.TemporaryDirectory() as directory:
            text = report.render({"TEST_OUTCOME": "failure"}, Path(directory), summary)
        self.assertIn("3 passed, 1 failed, 2 skipped", text)
        self.assertIn("RoomTests.testCachedSearch(): XCTAssertEqual failed", text)
        self.assertIn("No phase log was produced", text)

    def test_cancelled_execution_is_not_reported_as_an_assertion_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            logs = Path(directory)
            (logs / "tests.log").write_text("Waiting for SpringBoard\n")
            text = report.render({"TEST_OUTCOME": "cancelled"}, logs)
        self.assertIn("phase: Test execution", text)
        self.assertIn("Waiting for SpringBoard", text)
        self.assertNotIn("#### Test failures", text)

    def test_missing_tool_or_corrupt_bundle_does_not_raise(self):
        with tempfile.TemporaryDirectory() as directory:
            logs = Path(directory)
            for error in [FileNotFoundError("xcrun"), subprocess.TimeoutExpired("xcrun", 60)]:
                with self.subTest(error=error), patch.object(report.subprocess, "run", side_effect=error):
                    self.assertIsNone(report.read_result(Path("missing.xcresult"), "summary", logs))
            with patch.object(report.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "not JSON")):
                self.assertIsNone(report.read_result(Path("damaged.xcresult"), "summary", logs))

    def test_slowest_tests_keep_suite_names_and_numeric_order(self):
        tests = {"testNodes": [{"name": "Suite", "nodeType": "Test Suite", "children": [
            {"name": "fast", "nodeType": "Test Case", "durationInSeconds": 0.1},
            {"name": "slow", "nodeType": "Test Case", "durationInSeconds": 2.5},
            {"name": "skipped", "nodeType": "Test Case"},
        ]}]}
        with tempfile.TemporaryDirectory() as directory:
            text = report.render({"TEST_OUTCOME": "success"}, Path(directory), {}, tests)
        self.assertLess(text.index("Suite / slow"), text.index("Suite / fast"))
        self.assertNotIn("Suite / skipped", text)


if __name__ == "__main__":
    unittest.main()
