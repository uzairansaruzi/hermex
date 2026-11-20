#!/usr/bin/env python3
"""Fail when a Swift file gains a comment.

Swift source carries no comments: a decision worth recording goes in docs/adr/, and
the rest is said by the code. Files that still had comments when the rule landed are
listed with their comment-line count in ci/comment_baseline.txt, and that count may
only go down. A file not listed there allows none. On a pull request the baseline is
also held to the target branch's, so a PR cannot raise an allowance or add one.

A `// test-wait: <reason>` line that ci/check_test_waits.py reads for a wait in
HermesMobileTests/ is not counted and `--strip` keeps it. One with no reason, or
beside no wait, is a comment like any other.

PR CI runs the check in Tooling Tests; locally:

    python3 ci/check_comments.py                  check every Swift file against the baseline
    python3 ci/check_comments.py --update         lower the baseline to the current counts
    python3 ci/check_comments.py --list [path…]   print each comment block as a JSON line
    python3 ci/check_comments.py --strip path…    delete every comment in those files

The delete-comment skill (.agents/skills/delete-comment) walks the remaining baseline
down with `--list` and `--strip`.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

from check_test_waits import findings, line_finder, scan

REPO = Path(__file__).resolve().parent.parent
BASELINE = REPO / "ci" / "comment_baseline.txt"
TESTS = "HermesMobileTests/"


def keeps_waits(path):
    """Whether `path` is a test file, where `// test-wait:` lines are annotations."""
    return str(path).startswith(TESTS)


def comment_spans(source, waits=False):
    """The (start, end) index range of every comment `--strip` would delete. With
    `waits`, the `// test-wait: <reason>` line annotating a wait is left out."""
    line_of = line_finder(source)
    annotated = {at for _, _, reason, at in findings(source) if reason} if waits else set()
    return [(start, end) for start, end in scan(source)[2]
            if not (source.startswith("//", start) and line_of(start) in annotated)]


def comment_lines(source, waits=False):
    """The 1-based lines of `source` that hold a comment, in order."""
    line_of = line_finder(source)
    lines = set()
    for start, end in comment_spans(source, waits):
        lines.update(range(line_of(start), line_of(max(start, end - 1)) + 1))
    return sorted(lines)


def blocks(source, waits=False):
    """Each run of adjacent comment lines as (first line, last line, text)."""
    lines = source.split("\n")
    run = []
    for line in comment_lines(source, waits) + [None]:
        if run and line != run[-1] + 1:
            yield run[0], run[-1], "\n".join(lines[index - 1] for index in run)
            run = []
        run.append(line)


def strip(source, waits=False):
    """`source` without its comments. A line left empty goes, and so does the blank
    line it would otherwise leave doubled or stranded after an opening brace. A comment
    between two tokens leaves exactly one space."""
    spans = comment_spans(source, waits)
    if not spans:
        return source
    touched = set(comment_lines(source, waits))
    out, cursor = [], 0
    for start, end in spans:
        out.append(source[cursor:start])
        newlines = source.count("\n", start, end)
        inline = not newlines and 0 < start and end < len(source)
        joins = inline and not source[start - 1].isspace() and not source[end].isspace()
        doubles = inline and source[start - 1] == " " and source[end] == " "
        out.append("\n" * newlines if not joins else " ")
        cursor = end + 1 if doubles else end
    out.append(source[cursor:])
    kept = []
    removed_above = False
    for number, line in enumerate("".join(out).split("\n"), start=1):
        if number in touched:
            line = line.rstrip()
            if not line:
                removed_above = True
                continue
        if removed_above and not line.strip() and kept and (not kept[-1].strip() or kept[-1].rstrip().endswith(("{", "(", "["))):
            continue
        if removed_above and line.strip().startswith(("}", ")", "]")) and kept and not kept[-1].strip():
            kept.pop()
        removed_above = False
        kept.append(line)
    while len(kept) > 1 and not kept[0].strip():
        kept.pop(0)
    return "\n".join(kept)


def swift_files():
    """Every Swift file git tracks or would track, relative to the repo."""
    listed = subprocess.run(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "*.swift"],
                            cwd=REPO, capture_output=True, text=True, check=True).stdout
    return sorted(path for path in listed.split("\0") if path and (REPO / path).is_file())


def counts():
    """The comment-line count of each Swift file that has any."""
    found = {}
    for path in swift_files():
        count = len(comment_lines((REPO / path).read_text(encoding="utf-8"), keeps_waits(path)))
        if count:
            found[path] = count
    return found


def parse_baseline(text):
    allowed = {}
    for line in text.splitlines():
        count, path = line.split("\t")
        allowed[path] = int(count)
    return allowed


def read_baseline():
    return parse_baseline(BASELINE.read_text(encoding="utf-8")) if BASELINE.exists() else None


def target_baseline():
    """The baseline on the branch a pull request targets, or None outside a pull
    request and where the target has no baseline yet."""
    target = os.environ.get("GITHUB_BASE_REF")
    if not target:
        return None
    ref = f"origin/{target}"
    subprocess.run(["git", "rev-parse", "--verify", "--quiet", ref], cwd=REPO, capture_output=True, check=True)
    shown = subprocess.run(["git", "show", f"{ref}:{BASELINE.relative_to(REPO)}"], cwd=REPO, capture_output=True, text=True)
    return parse_baseline(shown.stdout) if shown.returncode == 0 else None


def update():
    """Write the baseline: the current counts the first time, and after that each
    file's count only if it is lower than the one recorded."""
    current, allowed = counts(), read_baseline()
    if allowed is not None:
        current = {path: min(count, allowed[path]) for path, count in current.items() if path in allowed}
    BASELINE.write_text("".join(f"{count}\t{path}\n" for path, count in sorted(current.items())), encoding="utf-8")
    print(f"{BASELINE.relative_to(REPO)}: {sum(current.values())} comment line(s) in {len(current)} file(s).")
    return 0


def drift(current, allowed):
    """Files holding more comment lines than the baseline allows, and files holding
    fewer, each as (path, count, allowed)."""
    over = [(path, count, allowed.get(path, 0)) for path, count in sorted(current.items()) if count > allowed.get(path, 0)]
    under = [(path, current.get(path, 0), count) for path, count in sorted(allowed.items()) if current.get(path, 0) < count]
    return over, under


def check():
    current, allowed = counts(), read_baseline() or {}
    target = target_baseline()
    raised = [] if target is None else drift(allowed, target)[0]
    for path, count, limit in raised:
        print(f"{BASELINE.relative_to(REPO)}: {path} allows {count} comment line(s), the target branch allows {limit}")
    if raised:
        print("\nThe baseline only goes down. Delete the comment instead; see ci/check_comments.py.", file=sys.stderr)
        return 1
    over, under = drift(current, allowed)
    for path, count, limit in over:
        line = comment_lines((REPO / path).read_text(encoding="utf-8"), keeps_waits(path))[0]
        print(f"{path}:{line}: {count} comment line(s), {limit} allowed")
    if over:
        print(f"\n{len(over)} Swift file(s) gained comments. Say it in the code, or record the decision in "
              "docs/adr/; see ci/check_comments.py.", file=sys.stderr)
        return 1
    if under:
        for path, count, limit in under:
            print(f"{path}: {count} comment line(s), baseline still allows {limit}")
        print("\nComments were removed. Lock that in: python3 ci/check_comments.py --update", file=sys.stderr)
        return 1
    print(f"No new Swift comments. {sum(allowed.values())} comment line(s) remain in {len(allowed)} file(s).")
    return 0


def repo_path(path):
    """`path` relative to the repo when it is inside it, however it was spelled."""
    resolved = (REPO / path).resolve()
    return str(resolved.relative_to(REPO) if resolved.is_relative_to(REPO) else resolved)


def main(argv):
    if argv[1:2] == ["--update"]:
        return update()
    paths = [repo_path(path) for path in argv[2:]]
    if argv[1:2] == ["--list"]:
        for path in paths or swift_files():
            for first, last, text in blocks((REPO / path).read_text(encoding="utf-8"), keeps_waits(path)):
                print(json.dumps({"file": path, "first": first, "last": last, "text": text}))
        return 0
    if argv[1:2] == ["--strip"]:
        for path in paths:
            source = (REPO / path).read_text(encoding="utf-8")
            (REPO / path).write_text(strip(source, keeps_waits(path)), encoding="utf-8")
        return 0
    return check()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
