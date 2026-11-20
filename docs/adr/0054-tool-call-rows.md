# 0054. Tool call rows and diffs

Area: chat-transcript

## Count webui's tool result snippet cap in Unicode scalars

A webui server cuts a tool result at `_TOOL_RESULT_SNIPPET_MAX` (`ToolCallDiff.snippetLimit`, 4,000), and Python slices by code point, so `ToolCallDiff.ResultReading` counts the cap in `unicodeScalars`. A cut result is never unescaped: a cut JSON envelope would then read as a diff.

Lives in: `HermesMobile/Features/Chat/ToolCallDiff.swift`

## Read the leading JSON envelope of hermes-agent tool results

hermes-agent stores a one-line JSON envelope for a tool result and then appends notes, such as subdirectory hints, after "\n\n". A reloaded result that no longer parses whole can still lead with the complete envelope, so `ToolCallDiff.ResultReading` reads it with `leadingEnvelope(of:)`.

Lives in: `HermesMobile/Features/Chat/ToolCallDiff.swift`

## Treat non-envelope write results as failed edits

The webui unwraps a failed edit's `error` into plain text, so in `ToolCallDiff.ResultReading` any other complete, non-envelope result means the args did not land and `allowsArgumentDiff` is false. The result reports no change only when `looksLikeWriteError` matches.

Lives in: `HermesMobile/Features/Chat/ToolCallDiff.swift`

## Recognize hermes-agent write errors by their leading text

hermes-agent's write and patch errors carry no marker once the webui unwraps them, so `ToolCallDiff`'s `writeErrorLead` recognizes them only by how they start; anything else, including success text that names an alarming path, landed. The leads and their sources at the pinned hermes-agent commit: "could not find" (`tools/fuzzy_match.py`, `tools/file_operations.py`); "found N (approximate) matches", "old_string is empty" or "only whitespace", "no edit was applied", "escape-drift detected" (`tools/fuzzy_match.py`); "failed to" and "post-write verification failed" (`tools/file_operations.py`); "refusing to write" or "overwrite" (`tools/file_operations.py`, `tools/file_tools_write_guards.py`); "write", "delete" or "move denied:" (`agent/file_safety.py`).

Lives in: `HermesMobile/Features/Chat/ToolCallDiff.swift`

## Draw a partial diff when webui drops an edit half

`ToolCallDiff.replacementCandidate` draws `-` lines from the old text and `+` lines from the new behind a counted header, so a line like `-- note` reads as a removal, not a `--- ` file header. A missing half is unknown, because the webui keeps only the first 4 live args, so the diff is partial rather than a false "+0". With `replace_all` the pair stands for every occurrence, so it draws without counts.

Lives in: `HermesMobile/Features/Chat/ToolCallDiff.swift`

## Parse tool exit codes with Int(exactly:)

`ToolCallDisplayFormatter` converts a numeric `exit_code` from tool output with `Int(exactly:)`, so an out-of-range value becomes `nil` instead of trapping (#62).

Lives in: `HermesMobile/Features/Chat/ToolCallDisplayFormatter.swift`

## Keep code-like tool content left-to-right in RTL chats

`ToolCallLogRowView` keeps commands, paths, and results left to right inside an RTL transcript (#259), like the live card, because they are code-like. Answered questions are prose and keep the transcript's direction.

Lives in: `HermesMobile/Features/Chat/ToolCallLogRowView.swift`

## Wrap tool output lines over 500 characters

`ToolCallDetailBodyView` renders a result as one `Text`, which keeps the whole result selectable but can't draw an arbitrarily wide line. `fitsOnOneTextLine` therefore wraps output with any line over 500 characters even when Wrap Lines is off.

Lives in: `HermesMobile/Features/Chat/ToolCallLogRowView.swift`

## Open expanded log bodies from zero height

`TranscriptLogRowBodyWindowLayout` reports a height of zero until the content has been measured, then the lesser of its natural height and the cap. Starting closed prevents one unbounded layout pass from moving the transcript before the cap takes effect. The first bounded measurement opens the body from zero, so rows below only move down toward their final positions; later content changes keep their non-animated sizing.

Lives in: `HermesMobile/Features/Chat/TranscriptLogRowView.swift`

## Never merge two stable tool-call IDs by name order

When `ToolCall` reconciles live and transcript calls, matching by name order (`matchingToolCallNameOrdinalIndex`) is a last resort for live fallback events whose args can be missing or truncated. It never collapses two stable transcript IDs into one call.

Lives in: `HermesMobile/Models/ToolCall.swift`

## Match an approval's shell key against the description last

`ApprovalScope` treats a key as a shell key when it is one `; `-joined part of the approval's description. That check runs last because the `execute_code` approval's description also mentions its key.

Lives in: `HermesMobile/Models/Approval.swift`
