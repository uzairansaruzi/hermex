# 0041. Approval summaries

Area: chat-transcript

## Keep an approval summary request alive across card remounts

`ApprovalSummaryLine` is optional model text with no relationship to the approval controls' enabled state, and it is mounted only while the plain-words switch is on. The request it shows, owned by `ApprovalSummaries`, outlives the view: a remount (a question taking the card's place, a room card moving up, a layout change) keeps it. `ApprovalSummaries.load` runs the loader in an unstructured `Task` so the presenting view's task ending does not cancel it. Only an accepted answer, a withdrawal, leaving, or the switch turning off ends it.

Lives in: `HermesMobile/Features/Chat/ApprovalSummary.swift`

## Keep approval summaries off by default

`ApprovalSummaries.enabledByDefault` is false: plain-words summaries stay off until the user opts in, because each summary is a model call on their own server.

Lives in: `HermesMobile/Features/Chat/ApprovalSummary.swift`

## Never request a second summary for one approval

`ApprovalSummaries.cancel`, used when leaving or turning the switch off, ends unfinished work but marks the key `.unavailable` instead of clearing it. A still-pending approval therefore never becomes eligible for a second model request; only `remove(_:)`, when the host settled or withdrew the approval, clears its state.

Lives in: `HermesMobile/Features/Chat/ApprovalSummary.swift`
