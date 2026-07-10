#!/usr/bin/env bash
# Advisory pre-merge triage-coverage check (AGY gap analysis, Phase 6 item 9).
#
# Warns when the LAST AGY review round on a PR reported findings but no human
# triage comment is newer than that round. Untriaged findings historically
# leaked exactly this way — review rounds landing in the same session the PR
# merged (#332 r3, #345 r3-r4, #353) were never dispositioned by anyone.
#
# Usage: check-triage-coverage.sh <pr-number>
# Exit 0: covered — triage is newer than the last review round, or that round
#         reported no actionable findings (nothing to disposition).
# Exit 3: ADVISORY WARNING — last round has undispositioned findings, or the
#         last round failed outright (head effectively unreviewed).
# Exit 1: usage/API error.
set -euo pipefail

REPO="uzairansaruzi/hermex"
PR="${1:?usage: check-triage-coverage.sh <pr-number>}"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
gh api "repos/${REPO}/issues/${PR}/comments" --paginate \
  --jq '[.[] | {created_at, updated_at, body}]' > "$TMP"

python3 - "$TMP" <<'PY'
import json, re, sys

raw = open(sys.argv[1]).read()
# --paginate emits one JSON array per page, concatenated; merge them.
dec, idx, comments = json.JSONDecoder(), 0, []
while idx < len(raw):
    try:
        obj, idx = dec.raw_decode(raw, idx)
    except json.JSONDecodeError:
        break
    comments.extend(obj)
    while idx < len(raw) and raw[idx] in " \n\r\t":
        idx += 1

MARK = re.compile(r"hermes-agy-(followup-)?review:")
FIND = re.compile(r"<!--\s*agy-findings-v1\s*-->\s*```json\s*(.*?)\s*```", re.S)

def stamp(c):
    return max(c.get("created_at") or "", c.get("updated_at") or "")

review_time, findings, failed = None, None, False
for c in comments:
    body = c.get("body") or ""
    if not MARK.search(body):
        continue
    t = stamp(c)
    if review_time is None or t > review_time:
        review_time = t
        failed = "## Hermes review failed" in body
        m = FIND.search(body)
        findings = None
        if m:
            try:
                findings = len(json.loads(m.group(1)))
            except Exception:
                findings = None

triage_time = max(
    (stamp(c) for c in comments
     if (c.get("body") or "").lstrip().startswith("## Review triage")),
    default="")

if review_time is None:
    print("no AGY review found on this PR — nothing to check")
    sys.exit(0)
if failed:
    print(f"WARNING: the last AGY review round FAILED (comment updated {review_time}) — "
          "the head is effectively unreviewed. Re-trigger with `/hermes review full` before merging.")
    sys.exit(3)
if findings == 0:
    print(f"last review round ({review_time}) reported no actionable findings — triage not required")
    sys.exit(0)

n = "unknown" if findings is None else findings
if triage_time > review_time:
    print(f"triage coverage OK: newest triage ({triage_time}) is newer than the "
          f"last review round ({review_time}, findings: {n})")
    sys.exit(0)

latest = triage_time or "never"
print(f"WARNING: last review round ({review_time}) reports {n} finding(s) but the "
      f"newest human triage comment is older ({latest}). Triage the final round before merging.")
sys.exit(3)
PY
