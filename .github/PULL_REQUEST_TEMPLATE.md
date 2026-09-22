<!-- Thanks for contributing! Please read CONTRIBUTING.md before opening a PR. -->

## Linked issue

<!-- Every PR should close an issue, e.g. "Fixes #123". If there is no issue yet, open one first. -->

Fixes #

## What changed

<!-- A short, plain-English summary of the change and why it's the right fix. -->

## How it was tested

<!-- e.g. focused XCTest selection (command + result), manual simulator steps, screenshots for UI changes. -->

## Checklist

- [ ] Local validation passes using `scripts/test-sim <assigned-simulator-udid>` with the tests required by `AGENTS.md` § Verifying; the selection and results are recorded above
- [ ] New/changed `Codable` models decode tolerantly (optionals for fields the server might add or rename)
- [ ] No new third-party dependencies (the list in `AGENTS.md` is locked)
- [ ] No invented API endpoints or JSON shapes (verified against upstream source or a running server)
