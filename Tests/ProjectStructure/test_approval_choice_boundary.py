import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP_ROOT = ROOT / "HermesMobile"

DECLARATION = re.compile(
    r"\b(?:enum|struct|class|protocol|typealias)\s+ApprovalChoice\b"
)


class ApprovalChoiceBoundaryTests(unittest.TestCase):
    def approval_choice_sources(self):
        return [
            path
            for path in APP_ROOT.rglob("*.swift")
            if "ApprovalChoice" in path.read_text()
        ]

    def test_app_sources_do_not_declare_typealias_wrap_or_shadow_approval_choice(self):
        declarations = []
        for path in APP_ROOT.rglob("*.swift"):
            for line_number, line in enumerate(path.read_text().splitlines(), start=1):
                if DECLARATION.search(line):
                    declarations.append(f"{path.relative_to(ROOT)}:{line_number}:{line.strip()}")

        self.assertEqual(declarations, [])

    def test_every_app_source_consuming_approval_choice_imports_watch_shared(self):
        missing_imports = [
            str(path.relative_to(ROOT))
            for path in self.approval_choice_sources()
            if "import WatchShared" not in path.read_text().splitlines()
        ]

        self.assertGreater(len(self.approval_choice_sources()), 0)
        self.assertEqual(missing_imports, [])


if __name__ == "__main__":
    unittest.main()
