# 0077. Move to Hermes journal

Area: move-to-hermes

## Put every intent on disk before what it names is sent

`MoveToHermesJournal` (#1216) is one Move's work state on disk: `plan.json` is the frozen Review, written once before the commit, and `log.jsonl` gets one JSON line per `MoveToHermesEvent`, numbered from 1. An intent (`importing`, `planned`, `changing`, `finished`) is on disk before what it names is sent or saved anywhere else; the other events record outcomes. `append` with `durable` flushes the line before it returns, so an intent is never acted on before it can survive a crash; on failure the line is cut off again and `append` throws, and the caller must not act on the event. Outcome lines are written without their own flush, and the next intent's flush covers them. The journal's folder sits under Application Support, named by a SHA-256 of both server ids so it holds no address, with the drafts' file protection.

Lives in: `HermesMobile/Features/MoveToHermes/MoveToHermesJournal.swift`

## Cut a torn last line and resume its intent's work as in flight

On read, a last line with no newline was cut short by a quit or a crash and is cut off. Its own write never finished, so if it was an intent, nothing it names was sent. If it was an outcome, the intent before it is complete and its work counts as in flight: an import is sent again, since the host skips ids it has, and a metadata write is only checked, never resent.

Lives in: `HermesMobile/Features/MoveToHermes/MoveToHermesJournal.swift`

## Treat a missing or inconsistent log as damaged, and an unreadable file as retryable

A missing log, a complete line that does not decode, broken numbering, or a line naming a chat or Profile the plan does not hold makes the journal `.damaged`. Nothing is done from a damaged journal; the user starts over from a fresh scan, as when the journal is lost. `MoveToHermesJournal.open` treats a `plan.json` without its `log.jsonl` as damaged because without the log nothing says what was sent, and replaying from an empty one could resend. A file that cannot be read now (locked before first unlock, an I/O error, a newer format) is `.unreadable`: it is kept and read again later, never treated as damaged or deleted.

Lives in: `HermesMobile/Features/MoveToHermes/MoveToHermesJournal.swift`

## Write the empty log before plan.json

`MoveToHermesJournal.create` writes the log first. A `plan.json` without its log reads back as a journal that lost its history, which is damaged.

Lives in: `HermesMobile/Features/MoveToHermes/MoveToHermesJournal.swift`

## Accept mapped destinations when validating a log line's Profile

`MoveToHermesJournal.decode` checks each line's Profile against the Review's `hermesProfiles` together with the mapped destinations. An import goes to a mapped destination, which a repeat move takes from the move record, and that destination may be missing from the Hermes Profiles listed at its Review.

Lives in: `HermesMobile/Features/MoveToHermes/MoveToHermesJournal.swift`

## Don't open a journal another runner holds

`MoveToHermesRunner.snapshot` reads the move's journal without changing `state`, and returns nil while another runner has claimed it. Opening a journal cuts a torn last line, and that line could be the one the other runner is in the middle of writing.

Lives in: `HermesMobile/Features/MoveToHermes/MoveToHermesRunner.swift`
