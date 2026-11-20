import sys
from pathlib import Path
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import check_comments


class CheckCommentsTests(unittest.TestCase):
    def test_counts_comments_and_leaves_strings_and_regexes(self):
        source = (
            "/// Doc.\n"
            "let url = \"https://example.com\" // trailing\n"
            "/* block\n"
            "   two */\n"
            "let text = \"\"\"\n"
            "// inside a string\n"
            "\"\"\"\n"
            "let quote = #\"\"\"#\n"
            "// after a one-line raw string\n"
            "let link = #/https?://example\\.com\\\\\\/#x//y/#\n"
            "let path = /a\"b\\/\\/c/ // after a regex\n"
            "let half = total / 2 // after a division\n"
            "let next = /* before a regex */ /a\\/\\// // after it\n"
            "if /a\"b/.wholeMatch(in: value) != nil {} // after a condition\n"
        )
        self.assertEqual(check_comments.comment_lines(source), [1, 2, 3, 4, 9, 11, 12, 13, 14])
        self.assertEqual(check_comments.strip(source).split("\n")[-3], "let next = /a\\/\\//")

    def test_a_wait_annotation_is_kept_only_beside_a_wait_in_tests(self):
        source = (
            "// test-wait: hangs until cancelled\n"
            "try await Task.sleep(for: .seconds(60))\n"
            "// test-wait: beside no wait\n"
            "let ready = true\n"
        )
        self.assertEqual(check_comments.comment_lines(source, waits=True), [3])
        self.assertEqual(check_comments.comment_lines(source), [1, 3])

    def test_strip_deletes_comments_and_the_gaps_they_leave(self):
        source = (
            "// Header.\n"
            "\n"
            "import Foundation\n"
            "\n"
            "/// Doc.\n"
            "struct A {\n"
            "    // MARK: State\n"
            "\n"
            "    let url = \"https://example.com\" // trailing\n"
            "    let/* between tokens */answer = 42\n"
            "\n"
            "    // Last.\n"
            "}\n"
        )
        self.assertEqual(check_comments.strip(source), (
            "import Foundation\n"
            "\n"
            "struct A {\n"
            "    let url = \"https://example.com\"\n"
            "    let answer = 42\n"
            "}\n"
        ))

    def test_a_file_may_not_gain_comments(self):
        over, _ = check_comments.drift({"Old.swift": 3, "New.swift": 1}, {"Old.swift": 2})
        self.assertEqual(over, [("New.swift", 1, 0), ("Old.swift", 3, 2)])

    def test_a_pull_request_may_not_raise_the_baseline(self):
        allowance = {"New.swift": 1}
        with mock.patch.multiple(check_comments, counts=lambda: allowance, read_baseline=lambda: allowance):
            with mock.patch.object(check_comments, "target_baseline", return_value={}):
                self.assertEqual(check_comments.check(), 1)
            with mock.patch.object(check_comments, "target_baseline", return_value=allowance):
                self.assertEqual(check_comments.check(), 0)

    def test_removed_comments_have_to_be_locked_in(self):
        _, under = check_comments.drift({"Old.swift": 1}, {"Old.swift": 2, "Gone.swift": 4})
        self.assertEqual(under, [("Gone.swift", 0, 4), ("Old.swift", 1, 2)])


if __name__ == "__main__":
    unittest.main()
