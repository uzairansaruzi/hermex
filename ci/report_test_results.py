#!/usr/bin/env python3
"""Summarize PR CI failures without changing the build/test verdict."""

import json
import os
from pathlib import Path
import re
import subprocess


PHASES = (
    ("TOOLCHAIN_OUTCOME", "Toolchain setup", "toolchain.log"),
    ("SELECTION_OUTCOME", "Simulator selection", "selection.log"),
    ("BUILD_OUTCOME", "Build for testing", "build.log"),
    ("TEST_OUTCOME", "Test execution", "tests.log"),
)


def read_result(bundle, report, logs):
    """Keep raw reports for diagnosis; a missing/damaged bundle is not a test verdict."""
    try:
        result = subprocess.run(
            ["xcrun", "xcresulttool", "get", "test-results", report,
             "--path", str(bundle), "--compact"],
            capture_output=True, text=True, timeout=60, check=True,
        )
        (logs / f"{report}.json").write_text(result.stdout)
        return json.loads(result.stdout)
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        (logs / f"{report}-error.txt").write_text(str(error))
        return None


def test_times(nodes, parents=()):
    for node in nodes:
        path = (*parents, node.get("name", "<unnamed>"))
        duration = node.get("durationInSeconds")
        if node.get("nodeType") == "Test Case" and isinstance(duration, (int, float)):
            yield duration, " / ".join(path)
        yield from test_times(node.get("children", []), path)


def code_block(text):
    # Test output can contain Markdown fences; keep it inside the diagnostic block.
    return "````text\n" + text.replace("```", "` ` `") + "\n````"


def render(outcomes, logs, summary=None, tests=None):
    lines = ["### PR CI results", "", "| Phase | Result |", "| --- | --- |"]
    for key, label, _ in PHASES:
        lines.append(f"| {label} | {outcomes.get(key) or 'not run'} |")
    failed = next((phase for phase in PHASES if outcomes.get(phase[0]) in ("failure", "cancelled")), None)
    if failed:
        _, label, filename = failed
        lines += ["", f"**Failed or interrupted phase: {label}.**"]
        log = logs / filename
        if log.exists():
            content = log.read_text(errors="replace").splitlines()
            errors = [line for line in content if re.search(r"error:|failed|timed out|unable to|lost connection", line, re.I)]
            lines += ["", code_block("\n".join((errors or content)[-30:])[:16000])]
        else:
            lines += ["", "No phase log was produced; inspect the Actions step log."]
    if summary is not None:
        lines += ["", f"Tests: {summary.get('passedTests', 0)} passed, "
                  f"{summary.get('failedTests', 0)} failed, {summary.get('skippedTests', 0)} skipped."]
        failures = summary.get("testFailures", [])
        if failures:
            lines += ["", "#### Test failures", "", code_block("\n\n".join(
                f"{failure.get('testName', 'Unnamed test')}: {failure.get('failureText', '')}"
                for failure in failures[:20]
            )[:20000])]
            if len(failures) > 20:
                lines += ["", "Further failures are in the summary.json artifact."]
    else:
        lines += ["", "Test summary unavailable. No assertion/infrastructure classification can be inferred from a missing result bundle."]
    if tests is not None:
        slowest = sorted(test_times(tests.get("testNodes", [])), reverse=True)[:20]
        lines += ["", "#### Slowest test cases", "", code_block("\n".join(
            f"{duration:8.3f}s  {name}" for duration, name in slowest
        ))]
    return "\n".join(lines) + "\n"


def main():
    logs = Path(os.environ.get("CI_LOG_DIR", "ci-logs"))
    logs.mkdir(parents=True, exist_ok=True)
    bundle = Path(os.environ.get("RESULT_BUNDLE_PATH", "TestResults.xcresult"))
    summary = read_result(bundle, "summary", logs) if bundle.exists() else None
    tests = read_result(bundle, "tests", logs) if bundle.exists() else None
    report = render(os.environ, logs, summary, tests)
    (logs / "report.md").write_text(report)
    print(report)
    if destination := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(destination, "a") as output:
            output.write(report)


if __name__ == "__main__":
    main()
