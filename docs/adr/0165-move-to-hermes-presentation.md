# 0165. Move to Hermes presentation

Area: ui-theming

## Keep one Move banner row so its sheet survives

`MoveToHermesBanner` uses one row for the invite and every notice, so a sheet opened from it survives the invite turning into a notice. The banner a sheet opened from keeps the row while its sheet is up, even though a running move has no banner of its own, so the sheet isn't torn down with it. The invite has no notice yet.

Lives in: `HermesMobile/Features/MoveToHermes/MoveToHermesView.swift`

## Watch the topmost presentation before asking the Move question

`MoveToHermesQuestionTiming` walks `presentedViewController` to the topmost layer and waits for that one's dismissal, because a full-screen cover takes the controllers beneath it out of the window.

Lives in: `HermesMobile/Features/MoveToHermes/MoveToHermesView.swift`

## Detect a presentation's dismissal with a hidden probe view

`MoveToHermesQuestionTiming.dismissal(of:)` returns when the controller's view leaves its window (it was dismissed) or the task is cancelled. UIKit has no public dismissal callback a non-owner can observe, so a hidden probe view in the presentation reports it.

Lives in: `HermesMobile/Features/MoveToHermes/MoveToHermesView.swift`
