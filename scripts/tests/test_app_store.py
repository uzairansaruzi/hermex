"""Verify that release commands require opting into writes and preserve file arguments."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "app-store"


class AppStoreCommandTests(unittest.TestCase):
    def run_command(self, *args):
        with tempfile.TemporaryDirectory() as directory:
            asc = Path(directory) / "asc"
            asc.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, sys\n"
                "print(json.dumps({'read_only': os.environ['ASC_READ_ONLY'], "
                "'app': os.environ['ASC_APP_ID'], 'args': sys.argv[1:]}))\n"
            )
            asc.chmod(0o755)
            env = dict(os.environ, PATH=f"{directory}:{os.environ['PATH']}",
                       ASC_READ_ONLY="0", ASC_APP_ID="another-app")
            return subprocess.run(
                [str(SCRIPT), *args], env=env, capture_output=True, text=True,
            )

    def test_default_blocks_writes_even_when_parent_environment_allows_them(self):
        result = self.run_command("testflight", "testers", "invite",
                                  "--email", "tester@example.com")
        self.assertEqual(result.returncode, 0, result.stderr)
        command = json.loads(result.stdout)
        self.assertEqual(command["read_only"], "1")
        self.assertNotEqual(command["app"], "another-app")

    def test_explicit_write_preserves_copy_file_argument(self):
        notes = "@file:/tmp/release copy/what to test.txt"
        result = self.run_command("--write", "builds", "test-notes", "update",
                                  "--build-id", "build-42", "--whats-new", notes)
        self.assertEqual(result.returncode, 0, result.stderr)
        command = json.loads(result.stdout)
        self.assertEqual(command["read_only"], "0")
        self.assertEqual(command["args"][-1], notes)
        self.assertNotIn("--write", command["args"])


if __name__ == "__main__":
    unittest.main()
