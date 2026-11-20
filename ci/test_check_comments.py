import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import check_comments


class CheckCommentsTests(unittest.TestCase):
    def test_counts_comments_and_leaves_strings_and_wait_annotations(self):
        source = (
            "/// Doc.\n"
            "let url = \"https://example.com\" // trailing\n"
            "/* block\n"
            "   two */\n"
            "let text = \"\"\"\n"
            "// inside a string\n"
            "\"\"\"\n"
            "// test-wait: hangs until the caller\n"
            "// cancels it\n"
            "try await Task.sleep(for: .seconds(60)) // not the annotation\n"
        )
        self.assertEqual(check_comments.comment_lines(source), [1, 2, 3, 4, 10])

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
            "\n"
            "    // Last.\n"
            "}\n"
        )
        self.assertEqual(check_comments.strip(source), (
            "import Foundation\n"
            "\n"
            "struct A {\n"
            "    let url = \"https://example.com\"\n"
            "}\n"
        ))

    def test_a_file_may_not_gain_comments(self):
        over, _ = check_comments.drift({"Old.swift": 3, "New.swift": 1}, {"Old.swift": 2})
        self.assertEqual(over, [("New.swift", 1, 0), ("Old.swift", 3, 2)])

    def test_removed_comments_have_to_be_locked_in(self):
        _, under = check_comments.drift({"Old.swift": 1}, {"Old.swift": 2, "Gone.swift": 4})
        self.assertEqual(under, [("Gone.swift", 0, 4), ("Old.swift", 1, 2)])


if __name__ == "__main__":
    unittest.main()
