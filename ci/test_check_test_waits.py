import subprocess
import sys
import tempfile
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parent / "check_test_waits.py"


class CheckTestWaitsTests(unittest.TestCase):
    """Runs the script the way CI does, against a scratch test directory."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)

    def tearDown(self):
        self.directory.cleanup()

    def run_check(self, swift):
        (self.root / "Support").mkdir(exist_ok=True)
        (self.root / "Support" / "Waits.swift").write_text(swift)
        return subprocess.run([sys.executable, str(SCRIPT), str(self.root)], capture_output=True, text=True)

    def assertFlags(self, swift, *lines):
        result = self.run_check(swift)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        flagged = [int(line.split(":")[1]) for line in result.stdout.splitlines() if line.endswith(">`")]
        self.assertEqual(flagged, list(lines), result.stdout)

    def assertPasses(self, swift):
        result = self.run_check(swift)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_flags_each_clock_wait_in_code(self):
        self.assertFlags(
            "func a() async throws {\n"
            "    try await Task.sleep(for: .milliseconds(20))\n"
            "    Thread.sleep(forTimeInterval: 0.3)\n"
            "    usleep(100)\n"
            "    RunLoop.main.run(until: Date().addingTimeInterval(0.1))\n"
            "    while Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }\n"
            "    while self.clock.now < deadline { if await done() { return } }\n"
            "}\n",
            2, 3, 4, 5, 6, 7,
        )

    def test_flags_a_loop_that_yields_until_a_signal_appears(self):
        self.assertFlags(
            "func wait() async {\n"
            "    guard deferred else { return }\n"
            "    while continuation == nil {\n"
            "        await Task.yield()\n"
            "    }\n"
            "    repeat { await Task.yield() } while !ready\n"
            "}\n",
            3, 6,
        )

    def test_flags_a_call_split_across_lines(self):
        self.assertFlags("func a() async throws {\n    try await Task\n        .sleep(for: .seconds(1))\n}\n", 2)

    def test_ignores_comments_strings_and_lone_yields(self):
        self.assertPasses(
            "/// Stands in for `Task.sleep`; /* while Date() < end */ never polls.\n"
            "func a() async {\n"
            '    let text = "Task.sleep(for: .seconds(1))"\n'
            '    let raw = #"Thread.sleep \\(0) "quoted""#\n'
            '    let interpolated = "\\(name("usleep(1)"))"\n'
            '    let block = """\n    RunLoop.main.run(until: date)\n    """\n'
            "    await Task.yield()\n"
            "    while queue.isEmpty == false { queue.removeFirst() }\n"
            "}\n"
        )

    def test_an_annotation_with_a_reason_exempts_the_line_it_sits_on_or_above(self):
        self.assertPasses(
            "func a() async throws {\n"
            "    try await Task.sleep(for: .seconds(3600)) // test-wait: hangs until the caller cancels it\n"
            "    // A stub for the reconnect default.\n"
            "    // test-wait: a factory default; every test passes its own delay\n"
            "    try await Task.sleep(for: $0)\n"
            "}\n"
        )

    def test_an_annotation_needs_a_reason_and_must_be_adjacent(self):
        result = self.run_check(
            "func a() async throws {\n"
            "    try await Task.sleep(for: .seconds(1)) // test-wait:\n"
            "    // test-wait: only reaches the next line\n"
            "\n"
            "    try await Task.sleep(for: .seconds(1))\n"
            "}\n"
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("Waits.swift:2: Task.sleep: a test-wait annotation needs a reason", result.stdout)
        self.assertIn("Waits.swift:5: Task.sleep: wait on a signal", result.stdout)


if __name__ == "__main__":
    unittest.main()
