# 0157. Hermes fixture capture

Area: testing

## Sanitize captured fixtures by allow-list

The fixture capture's `Sanitizer` turns a raw capture into fixture files by replacing every string value with a placeholder unless its key is on the allow-list (`keptStrings`, plus mode-specific keys). A field upstream adds later is therefore redacted by default rather than leaking into committed fixtures.

Lives in: `scripts/fixtures/HermesFixtureCapture.swift`

## Restrict fixture capture files to owner before writing

`HermesFixtureCapture.writePrivately` writes the unsanitized capture readable only by its owner, from the first byte. It opens the file with mode 0600 and then calls `fchmod(descriptor, 0o600)` before writing, because an existing file keeps its old mode through `O_CREAT`.

Lives in: `scripts/fixtures/HermesFixtureCapture.swift`

## Cancel the socket to end a pending WebSocket receive

In the capture's timed socket receive, the timeout task calls `socket.cancel(with: .goingAway, reason: nil)` before throwing. A pending receive ignores task cancellation; only closing the socket ends it.

Lives in: `scripts/fixtures/HermesFixtureCapture.swift`
