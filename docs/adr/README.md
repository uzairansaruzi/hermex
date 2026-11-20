# Architecture decision records

Swift source in this repo carries no comments (`ci/check_comments.py`). A decision the
code cannot show lives here instead: a server contract quirk, an iOS or SwiftUI
behavior, a past bug, a performance, privacy, or security rule, an ordering dependency.
The test for writing one down is that an engineer reading only the code could simplify
it and bring back a user-visible bug.

What the code does belongs in its names and types. How to work in an area belongs in
`docs/agents/`. Vocabulary belongs in `CONTEXT.md`.

## Format

One file per subject (a screen, a client, a protocol), named `NNNN-subject.md` with the
next free number. A subject holds its decisions as sections:

```markdown
# 0042. Kanban live updates

Area: kanban

## Ping the events socket every 25 s

The host sends no heartbeat, and a tunnel such as Cloudflare closes a quiet socket at
about 100 s. `HermesKanbanEventStream` pings every 25 s and reconnects when a ping sees
neither its pong nor a frame (#1045).

Lives in: `HermesMobile/Networking/Hermes/HermesKanbanClient.swift`
```

- The heading is the decision as an imperative phrase.
- The body says what forces it, what the code does, and what breaks if it is undone,
  naming the types and functions involved and the issues that led to it.
- `Lives in` lists the files, so a search for a file name finds every decision about it.

## Keeping them true

- Changing code a decision covers changes the decision in the same PR. A decision that
  no longer holds is deleted, not marked superseded: git has the history.
- A new decision joins the subject it belongs to before it starts a new file.
- The first records came from the comments that used to hold these decisions, sorted out
  by the `delete-comment` skill.
