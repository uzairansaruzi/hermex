#!/usr/bin/env python3
"""Fail when an XCTest waits on the clock or polls instead of waiting on a signal.

Tests wait on expectations, observation (`waitUntil`) and scripted fixtures, never on
elapsed time (CLAUDE.md § Verifying). This scans every Swift file under
HermesMobileTests/, Support helpers included, outside comments, string literals and
regex literals, for the known forms:

- `Task.sleep`, `Thread.sleep`, `usleep(` and `RunLoop.main/current.run(…)`;
- deadline loops: `while Date() < …` and `while <clock>.now < …`;
- a `while` or `repeat` loop whose body awaits `Task.yield()`.

It guards those patterns, not every way to poll. A real delay that a test needs, such
as a hang stub its caller cancels or a factory default no test runs, carries an
adjacent reason, on the same line or in the comment lines directly above it:

    // test-wait: hangs until the caller's timeout cancels it

A `test-wait:` with no reason does not count. PR CI runs it in Tooling Tests; locally:

    python3 ci/check_test_waits.py [directory]
"""

import bisect
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_ROOT = REPO / "HermesMobileTests"

CALLS = [
    ("Task.sleep", re.compile(r"\bTask\s*\.\s*sleep\b")),
    ("Thread.sleep", re.compile(r"\bThread\s*\.\s*sleep\b")),
    ("usleep", re.compile(r"\busleep\s*\(")),
    ("RunLoop.run", re.compile(r"\bRunLoop\s*\.\s*(?:main|current)\s*\.\s*run\s*\(")),
    ("deadline loop", re.compile(r"\bwhile\s+(?:Date\s*\(\s*\)|[A-Za-z_][\w.]*\s*\.\s*now)\s*<")),
]
LOOP = re.compile(r"\b(while|repeat)\b")
YIELD = re.compile(r"\bTask\s*\.\s*yield\s*\(")
ANNOTATION = re.compile(r"test-wait:(.*)")
TOKEN = re.compile(r'//|/\*|#*"|#+/|/|[()\[\]{}]')
REGEX_OPENERS = "=(,:[{;!&|?"
REGEX_KEYWORDS = ("return", "in", "case", "try", "await", "if", "guard", "while", "where", "else", "switch", "throw")


def line_finder(text):
    """A function from an index in `text` to its 1-based line."""
    newlines = [index for index, char in enumerate(text) if char == "\n"]
    return lambda index: bisect.bisect_left(newlines, index) + 1


def mask(source):
    """Return `source` with comments, string literals and regex literals blanked out
    (newlines kept), and each line's comment text by line number."""
    code, comments, _ = scan(source)
    return code, comments


def scan(source):
    """`mask`, plus the (start, end) index range of every comment. ci/check_comments.py
    counts and strips comments from those ranges."""
    out = list(source)
    comments = {}
    spans = []
    length = len(source)
    line_of = line_finder(source)

    def blank(start, end):
        for index in range(start, end):
            if out[index] != "\n":
                out[index] = " "

    def skip_string(index):
        """`index` is at the string's opening `#`s or quote; returns the index after it."""
        hashes = 0
        while source[index] == "#":
            hashes += 1
            index += 1
        multiline = source.startswith('"""', index)
        if multiline and hashes:
            line_end = source.find("\n", index)
            if '"' + "#" * hashes in source[index + 1:length if line_end == -1 else line_end]:
                multiline = False
        index += 3 if multiline else 1
        closer = ('"""' if multiline else '"') + "#" * hashes
        escape = "\\" + "#" * hashes
        while index < length:
            if source.startswith(escape, index):
                after = index + len(escape)
                if after < length and source[after] == "(":
                    index = skip_code(after + 1, ")")
                else:
                    index = after + 1
                continue
            if source.startswith(closer, index):
                return index + len(closer)
            if source[index] == "\n" and not multiline:
                return index
            index += 1
        return index

    def escaped(index):
        """Whether an odd run of backslashes ends just before `index`."""
        run = 0
        while index - run - 1 >= 0 and source[index - run - 1] == "\\":
            run += 1
        return run % 2 == 1

    def regex_end(index):
        """`index` is at a `/` or at the `#`s of `#/`; returns the index after the regex
        literal that starts there, or None when a slash there is an operator."""
        hashes = 0
        while source[index + hashes] == "#":
            hashes += 1
        body = index + hashes + 1
        if hashes:
            close = source.find("/" + "#" * hashes, body)
            while close != -1 and escaped(close):
                close = source.find("/" + "#" * hashes, close + 1)
            return None if close == -1 else close + 1 + hashes
        if body >= length or source[body] in " \t\n=":
            return None
        before = index - 1
        comment = len(spans) - 1
        while before >= 0 and (source[before] in " \t\n" or (comment >= 0 and spans[comment][1] == before + 1)):
            if source[before] in " \t\n":
                before -= 1
            else:
                before = spans[comment][0] - 1
                comment -= 1
        if before >= 0 and source[before] not in REGEX_OPENERS:
            word = re.search(r"[A-Za-z_]\w*$", source[max(0, before - 16):before + 1])
            if not word or word.group() not in REGEX_KEYWORDS:
                return None
        while body < length and source[body] != "\n":
            if source[body] == "\\":
                body += 2
            elif source[body] == "/":
                return body + 1
            else:
                body += 1
        return None

    def skip_code(index, until):
        """Masks code from `index` to the unmatched `until` (or the end); returns the index after it."""
        depth = 0
        while True:
            token = TOKEN.search(source, index)
            if not token:
                return length
            index = token.start()
            text = token.group()
            if text == "//":
                end = source.find("\n", index)
                end = length if end == -1 else end
                comments.setdefault(line_of(index), []).append(source[index + 2:end])
                spans.append((index, end))
                blank(index, end)
                index = end
            elif text == "/*":
                start, nesting = index, 0
                while index < length:
                    if source.startswith("/*", index):
                        nesting += 1
                        index += 2
                    elif source.startswith("*/", index):
                        nesting -= 1
                        index += 2
                        if nesting == 0:
                            break
                    else:
                        index += 1
                spans.append((start, index))
                blank(start, index)
            elif text.endswith('"'):
                start = index
                index = skip_string(index)
                blank(start, index)
            elif text.endswith("/"):
                end = regex_end(index)
                if end is not None:
                    blank(index, end)
                index = end or index + len(text)
            elif until is None:
                index += 1
            elif text in "([{":
                depth += 1
                index += 1
            else:
                index += 1
                if depth == 0 and text == until:
                    return index
                depth -= 1

    skip_code(0, None)
    return "".join(out), comments, spans


def body_range(code, start):
    """The `{ … }` body of the loop whose keyword ends at `start`, as (open, close)."""
    depth = 0
    index = start
    while index < len(code):
        char = code[index]
        if char in "([":
            depth += 1
        elif char in ")]":
            depth -= 1
        elif char == "{" and depth == 0:
            break
        index += 1
    else:
        return None
    open_index, nesting = index, 0
    while index < len(code):
        if code[index] == "{":
            nesting += 1
        elif code[index] == "}":
            nesting -= 1
            if nesting == 0:
                return open_index, index
        index += 1
    return None


def closes_repeat(code, index):
    """Whether the `while` at `index` is the bodyless tail of `repeat { … } while cond`."""
    before = code[:index].rstrip()
    if not before.endswith("}"):
        return False
    nesting = 0
    for position in range(len(before) - 1, -1, -1):
        if before[position] == "}":
            nesting += 1
        elif before[position] == "{":
            nesting -= 1
            if nesting == 0:
                return before[:position].rstrip().endswith("repeat")
    return False


def findings(source):
    """Yield (line, kinds, reason, annotated) for every line that waits; `reason` is its
    annotation's, "" for one without a reason, or None, and `annotated` the line the
    annotation is on. ci/check_comments.py keeps the comments on those lines."""
    code, comments = mask(source)
    lines = code.split("\n")
    line_of = line_finder(code)

    def annotation(line):
        """The reason annotating `line` ("" for an empty one) and the line it is on,
        or None twice."""
        candidates = [line]
        above = line - 1
        while above >= 1 and not lines[above - 1].strip() and above in comments:
            candidates.append(above)
            above -= 1
        for candidate in candidates:
            for comment in comments.get(candidate, []):
                match = ANNOTATION.search(comment)
                if match:
                    return match.group(1).strip(), candidate
        return None, None

    found = {}
    for kind, pattern in CALLS:
        for match in pattern.finditer(code):
            found.setdefault(line_of(match.start()), []).append(kind)
    for match in LOOP.finditer(code):
        if match.group(1) == "while" and closes_repeat(code, match.start()):
            continue
        body = body_range(code, match.end())
        if body and YIELD.search(code, body[0], body[1]):
            found.setdefault(line_of(match.start()), []).append("Task.yield loop")
    for line in sorted(found):
        yield (line, ", ".join(found[line]), *annotation(line))


def check(root):
    """Return the report lines for every unannotated wait under `root`."""
    report = []
    for path in sorted(Path(root).rglob("*.swift")):
        source = path.read_text(encoding="utf-8")
        for line, kind, reason, _ in findings(source):
            if reason:
                continue
            try:
                shown = path.relative_to(REPO)
            except ValueError:
                shown = path
            problem = "a test-wait annotation needs a reason" if reason == "" else "wait on a signal, or add `// test-wait: <reason>`"
            report.append(f"{shown}:{line}: {kind}: {problem}\n    {source.splitlines()[line - 1].strip()}")
    return report


def main(argv):
    root = Path(argv[1]) if len(argv) > 1 else DEFAULT_ROOT
    report = check(root)
    for entry in report:
        print(entry)
    if report:
        print(f"\n{len(report)} test wait(s) poll or sleep. Tests wait on expectations, observation or "
              "scripted fixtures; see ci/check_test_waits.py.", file=sys.stderr)
        return 1
    print(f"No unannotated sleeps or polling loops under {root}.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
