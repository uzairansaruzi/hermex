#!/usr/bin/env python3
"""Fail when a Swift file gains a comment.

Swift source carries no comments: a decision worth recording goes in docs/adr/, and
the rest is said by the code. Files that still had comments when the rule landed are
listed with their comment-line count in ci/comment_baseline.txt, and that count may
only go down. A file not listed there allows none.

A `// test-wait: <reason>` annotation is read by ci/check_test_waits.py, so it and the
comment lines that finish its reason are not counted and `--strip` keeps them.

PR CI runs the check in Tooling Tests; locally:

    python3 ci/check_comments.py                  check every Swift file against the baseline
    python3 ci/check_comments.py --update         lower the baseline to the current counts
    python3 ci/check_comments.py --list [path…]   print each comment block as a JSON line
    python3 ci/check_comments.py --strip path…    delete every comment in those files

The delete-comment skill (.agents/skills/delete-comment) walks the remaining baseline
down with `--list` and `--strip`.
"""

import json
import subprocess
import sys
from pathlib import Path

from check_test_waits import line_finder, scan

REPO = Path(__file__).resolve().parent.parent
BASELINE = REPO / "ci" / "comment_baseline.txt"
KEPT = "test-wait:"


def comment_spans(source):
    """The (start, end) index range of every comment `--strip` would delete: all but a
    `test-wait:` annotation and the comment-only lines directly under it."""
    line_of = line_finder(source)
    lines = source.split("\n")
    spans, annotation_line = [], None
    for start, end in scan(source)[2]:
        line = line_of(start)
        continues = line - 1 == annotation_line and lines[line - 1].lstrip().startswith("//")
        if KEPT in source[start:end] or continues:
            annotation_line = line
        else:
            spans.append((start, end))
    return spans


def comment_lines(source):
    """The 1-based lines of `source` that hold a comment, in order."""
    line_of = line_finder(source)
    lines = set()
    for start, end in comment_spans(source):
        lines.update(range(line_of(start), line_of(max(start, end - 1)) + 1))
    return sorted(lines)


def blocks(source):
    """Each run of adjacent comment lines as (first line, last line, text)."""
    lines = source.split("\n")
    run = []
    for line in comment_lines(source) + [None]:
        if run and line != run[-1] + 1:
            yield run[0], run[-1], "\n".join(lines[index - 1] for index in run)
            run = []
        run.append(line)


def strip(source):
    """`source` without its comments. A line left empty goes, and so does the blank
    line it would otherwise leave doubled or stranded after an opening brace."""
    spans = comment_spans(source)
    if not spans:
        return source
    touched = set(comment_lines(source))
    out, cursor = [], 0
    for start, end in spans:
        out.append(source[cursor:start])
        out.append("\n" * source.count("\n", start, end))
        cursor = end
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
        count = len(comment_lines((REPO / path).read_text(encoding="utf-8")))
        if count:
            found[path] = count
    return found


def read_baseline():
    if not BASELINE.exists():
        return None
    allowed = {}
    for line in BASELINE.read_text(encoding="utf-8").splitlines():
        count, path = line.split("\t")
        allowed[path] = int(count)
    return allowed


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
    over, under = drift(current, allowed)
    for path, count, limit in over:
        line = comment_lines((REPO / path).read_text(encoding="utf-8"))[0]
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


def main(argv):
    if argv[1:2] == ["--update"]:
        return update()
    if argv[1:2] == ["--list"]:
        for path in argv[2:] or swift_files():
            for first, last, text in blocks((REPO / path).read_text(encoding="utf-8")):
                print(json.dumps({"file": path, "first": first, "last": last, "text": text}))
        return 0
    if argv[1:2] == ["--strip"]:
        for path in argv[2:]:
            source = (REPO / path).read_text(encoding="utf-8")
            (REPO / path).write_text(strip(source), encoding="utf-8")
        return 0
    return check()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
