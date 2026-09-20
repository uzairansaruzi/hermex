"""Run with: python3 -m unittest discover -s scripts/tests -v"""

from contextlib import redirect_stdout
import importlib.machinery
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "test-sim"
loader = importlib.machinery.SourceFileLoader("test_sim_runner", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
runner = importlib.util.module_from_spec(spec)
loader.exec_module(runner)


class SimulatorRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.device = dict(name="iPhone 17", udid="SIM-A", state="Booted",
                           isAvailable=True, runtime="com.apple.CoreSimulator.SimRuntime.iOS-27-0")
        self.commands = []
        self.exit_code = 0
        self.failed = 0
        self.boot_failed = False

    def fake_run(self, command, output, timeout, lock_fds=()):
        self.commands.append(command)
        if command[:4] == ["xcrun", "simctl", "list", "devices"]:
            output.write_text(json.dumps({"devices": {self.device["runtime"]: [self.device]}}))
        elif command[:3] == ["xcrun", "simctl", "bootstatus"]:
            return int(self.boot_failed)
        elif command[0] == "xcodebuild":
            Path(command[command.index("-resultBundlePath") + 1]).mkdir()
            output.write_text("test log\n")
            return self.exit_code
        elif command[:3] == ["xcrun", "xcresulttool", "get"]:
            output.write_text(json.dumps(dict(passedTests=5, failedTests=self.failed,
                                             skippedTests=1, testFailures=[])))
        else:
            self.fail("Unexpected command: " + str(command))
        return 0

    def invoke(self, checkout="one/hermex", extra=()):
        with patch.object(runner, "__file__", str(self.home / checkout / "scripts/test-sim")), \
                patch.object(runner.Path, "home", return_value=self.home), \
                patch.object(runner, "run", side_effect=self.fake_run), \
                patch.object(sys, "argv", ["test-sim", "SIM-A", *extra]), \
                redirect_stdout(io.StringIO()):
            return runner.main()

    def test_serial_signed_build_and_focused_selection(self):
        self.assertEqual(self.invoke(extra=("--only", "HermesMobileTests/BotLiveActivityTests")), 0)
        command = next(c for c in self.commands if c[0] == "xcodebuild")
        self.assertIn("platform=iOS Simulator,id=SIM-A", command)
        self.assertEqual(command[command.index("-parallel-testing-enabled") + 1], "NO")
        self.assertEqual(command[command.index("-collect-test-diagnostics") + 1], "never")
        self.assertIn("-only-testing:HermesMobileTests/BotLiveActivityTests", command)
        self.assertFalse(any("CODE_SIGNING_ALLOWED" in c for c in command))
        self.assertNotIn("-retry-tests-on-failure", command)
        self.assertNotIn("-test-iterations", command)

    def test_same_basename_worktrees_have_distinct_build_directories(self):
        self.assertEqual(self.invoke("one/hermex"), 0)
        self.assertEqual(self.invoke("two/hermex"), 0)
        paths = [c[c.index("-derivedDataPath") + 1] for c in self.commands if c[0] == "xcodebuild"]
        self.assertNotEqual(paths[0], paths[1])

    def test_ambiguous_names_require_udid(self):
        second = dict(self.device, udid="SIM-B")
        with self.assertRaisesRegex(runner.RunnerError, "Ambiguous"):
            runner.select_device([self.device, second], "iPhone 17")
        self.assertEqual(runner.select_device([self.device, second], "SIM-B"), second)

    def test_boot_failure_does_not_start_tests_or_retry(self):
        self.boot_failed = True
        self.assertEqual(self.invoke(), 2)
        self.assertFalse(any(c[0] == "xcodebuild" for c in self.commands))
        self.assertEqual(sum(c[:3] == ["xcrun", "simctl", "bootstatus"] for c in self.commands), 1)

    def test_test_failure_is_returned_without_retry(self):
        self.exit_code = 65
        self.failed = 1
        self.assertEqual(self.invoke(), 1)
        self.assertEqual(sum(c[0] == "xcodebuild" for c in self.commands), 1)

    def test_failed_results_cannot_be_reported_as_success(self):
        self.failed = 1
        self.assertEqual(self.invoke(), 2)

    def test_simulator_locks_allow_other_devices_and_release_after_failure(self):
        first, second = self.home / "SIM-A.lock", self.home / "SIM-B.lock"
        with self.assertRaisesRegex(RuntimeError, "simulated failure"):
            with runner.lock(first, "first worktree"):
                with self.assertRaisesRegex(runner.RunnerError, "first worktree"):
                    with runner.lock(first, "second worktree"):
                        self.fail("Two owners entered the same simulator")
                with runner.lock(second, "second worktree"):
                    raise RuntimeError("simulated failure")
        with runner.lock(first, "next run"), runner.lock(second, "next run"):
            pass

    def test_child_keeps_lock_until_it_exits(self):
        path = self.home / "SIM-A.lock"
        with runner.lock(path, "active child") as fd:
            child = subprocess.Popen([sys.executable, "-c", "import sys; sys.stdin.read()"],
                                     stdin=subprocess.PIPE, pass_fds=(fd,))
        try:
            with self.assertRaises(runner.RunnerError):
                with runner.lock(path, "competitor"):
                    self.fail("Inherited lock released early")
        finally:
            child.communicate(timeout=5)
        with runner.lock(path, "after child exit"):
            pass

    def test_timeout_stops_the_spawned_process(self):
        with patch.object(runner.subprocess, "Popen", wraps=subprocess.Popen) as spawn:
            with self.assertRaises(subprocess.TimeoutExpired):
                runner.run([sys.executable, "-c", "import signal; signal.pause()"],
                           self.home / "timeout.log", timeout=0.1)
            self.assertEqual(spawn.call_count, 1)
        # run() reaps its child before propagating the timeout.


if __name__ == "__main__":
    unittest.main()
