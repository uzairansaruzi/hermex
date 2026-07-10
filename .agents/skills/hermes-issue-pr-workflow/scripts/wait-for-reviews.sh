#!/usr/bin/env bash
# Wait for the PR review bot(s) on a hermex PR.
#   - Hermes Antigravity review: issue comment containing "hermes-agy-review:" or
#     "hermes-agy-followup-review:" (posted by webhook from the owner account)
#   - Cursor Bugbot: a completed "Cursor Bugbot" check run on the head SHA
#     (fires even when Bugbot finds nothing; findings, if any, arrive as a
#     review authored by "cursor[bot]")
#
# Cursor Bugbot is TEMPORARILY DISABLED (owner out of usage, 2026-06-14), so by
# default this script only waits for the Antigravity review and never blocks on
# the Bugbot check run (which would otherwise burn the full timeout). Re-enable
# the Bugbot wait when usage is back:  WAIT_FOR_BUGBOT=1 wait-for-reviews.sh ...
#
# Usage: wait-for-reviews.sh <pr-number> [timeout-seconds] [poll-seconds]
#   Env: WAIT_FOR_BUGBOT=1  also require the Cursor Bugbot check (default 0 = skip).
# Exit 0: required review(s) detected. Exit 2: timeout (prints which landed). Exit 1: usage/repo error.

set -euo pipefail

REPO="uzairansaruzi/hermex"
PR="${1:?usage: wait-for-reviews.sh <pr-number> [timeout-seconds] [poll-seconds]}"
TIMEOUT="${2:-1800}"
POLL="${3:-90}"
WAIT_FOR_BUGBOT="${WAIT_FOR_BUGBOT:-0}"

# Only count activity after the PR's current head commit was pushed, so a
# follow-up wait after new commits doesn't match stale reviews of older code.
SINCE="$(gh pr view "$PR" --repo "$REPO" --json commits \
  --jq '.commits[-1].committedDate')"
echo "PR #${PR}: waiting for reviews newer than head commit (${SINCE})," \
     "timeout ${TIMEOUT}s, polling every ${POLL}s"

elapsed=0
agy=""
# Cursor Bugbot temporarily disabled: pre-mark it satisfied so the loop never
# blocks on a check run that won't appear. Set WAIT_FOR_BUGBOT=1 to wait for it.
if [[ "$WAIT_FOR_BUGBOT" == "1" ]]; then
  bugbot=""
else
  bugbot="skip"
  echo "Cursor Bugbot wait DISABLED (WAIT_FOR_BUGBOT=0) — only requiring the Antigravity review."
fi

while true; do
  if [[ -z "$agy" ]]; then
    agy="$(gh api "repos/${REPO}/issues/${PR}/comments" --paginate \
      --jq "[.[] | select(.created_at > \"${SINCE}\")
                 | select(.body | test(\"hermes-agy-(followup-)?review:\"))] | length")"
    [[ "$agy" != "0" ]] || agy=""
    [[ -z "$agy" ]] || echo "✓ Antigravity review landed (${elapsed}s)"
  fi

  if [[ -z "$bugbot" ]]; then
    head_sha="$(gh pr view "$PR" --repo "$REPO" --json headRefOid --jq '.headRefOid')"
    bugbot_run="$(gh api "repos/${REPO}/commits/${head_sha}/check-runs" \
      --jq "[.check_runs[] | select(.name == \"Cursor Bugbot\")
                           | select(.status == \"completed\")] | first | .conclusion // empty")"
    if [[ -n "$bugbot_run" ]]; then
      bugbot="yes"
      echo "✓ Cursor Bugbot check run completed: ${bugbot_run} (${elapsed}s)"
    fi
  fi

  if [[ -n "$agy" && -n "$bugbot" ]]; then
    if [[ "$bugbot" == "skip" ]]; then
      echo "Antigravity review landed after ${elapsed}s (Bugbot wait disabled)."
    else
      echo "Both reviews landed after ${elapsed}s."
    fi
    exit 0
  fi

  if (( elapsed >= TIMEOUT )); then
    echo "TIMEOUT after ${elapsed}s."
    [[ -n "$agy" ]] && echo "  Antigravity: landed" || echo "  Antigravity: MISSING"
    if [[ "$bugbot" == "skip" ]]; then
      echo "  Cursor Bugbot: skipped (WAIT_FOR_BUGBOT=0)"
    else
      [[ -n "$bugbot" ]] && echo "  Cursor Bugbot: landed" || echo "  Cursor Bugbot: missing (likely no findings)"
    fi
    exit 2
  fi

  sleep "$POLL"
  elapsed=$(( elapsed + POLL ))
done
