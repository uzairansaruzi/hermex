# Bot desktop viewer

This bundle uses **noVNC 1.7.0**, tag `v1.7.0`, upstream commit
`63107bd06d9e1f6136ff21aeda8cd62cbf0d433e`:
https://github.com/novnc/noVNC/tree/63107bd06d9e1f6136ff21aeda8cd62cbf0d433e

The complete upstream `core/` and `vendor/` source trees are included in
`novnc/`, with the source modifications described below. This is the
corresponding source for `viewer.js`; no CDN or remotely downloaded code is
used at runtime. Upstream source archive:
https://github.com/novnc/noVNC/archive/63107bd06d9e1f6136ff21aeda8cd62cbf0d433e.tar.gz

## Licenses

- noVNC core: Mozilla Public License 2.0, including modified `core/rfb.js`.
  See `novnc/LICENSE.txt`, `novnc/AUTHORS`, and
  `novnc/docs/LICENSE.MPL-2.0`. Original per-file copyright and license
  headers are retained in the included source.
- Included third-party source has its upstream notices intact; BSD license
  texts are in `novnc/docs/`. See the upstream license inventory in
  `novnc/LICENSE.txt` and the source file headers for individual authors.
- The upstream-vendored ES-module adaptation of pako 1.0.3 is included under
  the MIT license at `novnc/vendor/pako/LICENSE`. Its provenance is in
  `novnc/vendor/pako/README.md`.
- Hermex's bridge, input adapter, HTML, CSS and build/test scripts use the repository's MIT
  license. The noVNC source files remain governed by their original licenses.

## Hermex modifications to noVNC

`novnc/core/rfb.js` has only these view-only changes, marked `Hermex` in
source (2026-11-03):

1. Omit extended-clipboard capability negotiation.
2. Omit both Cursor and VMwareCursor pseudoencodings, allowing compatible
   VNC servers to composite the remote pointer into framebuffer updates.
   Actual cursor visibility still depends on the server's implementation.
3. Consume and discard standard and extended server clipboard payloads
   while view-only, before parsing, dispatching or replying to them.

No other upstream source files are modified. Trailing whitespace in AUTHORS and
license notice text is removed without changing its content. Keep the source, notices and
this modification record when redistributing or updating this bundle.

## Rebuilding

From the repository root, with Node/npm installed:

    scripts/build-bot-desktop-viewer.sh
    node --test scripts/tests/test-bot-desktop-bridge.cjs

The build tool is pinned to esbuild 0.25.12 and fetched from the official npm
registry if not cached. It is a build-only dependency. `viewer.js` is checked
in so Xcode and app launch require neither npm nor network access. ESM is
bundled inside an async classic-script wrapper to preserve upstream's
WebCodecs feature-detection await without relying on file-URL module loading.

For optional real headless-Chromium protocol/rendering coverage, point
`BOT_DESKTOP_PLAYWRIGHT_MODULE` to an installed Playwright module and,
optionally, `CHROMIUM_PATH` to Chromium, then run the same Node test command.
This is not a substitute for the signed iOS/WKWebView integration test.

## Native boundary

Native code owns endpoint URLs, proxy authorization, cookies, viewer ids,
tickets and the URLSessionWebSocketTask. The page receives RFB bytes and
generation-scoped commands:

- `HermexDesktop.open(generation)`
- `HermexDesktop.receive(base64, generation)`
- `HermexDesktop.input(command, args, generation)`
- `HermexDesktop.disconnect()` (silent native teardown)

The `desktop` WKScriptMessageHandler receives `ready`, or session-scoped
`send` (base64 `data`), `close`, `connected`, `frame`,
`clipboard` and `failed` messages. `connected` reports the RFB
handshake and `frame` reports the first complete framebuffer update after
drawing. The `input.js` overlay owns gestures and input; noVNC's canvas
does not receive touch events. It starts view-only. Only a server-confirmed
lease enables remote input or clipboard, and the Hermes server also filters
these messages by lease at the RFB boundary.

Browser networking is blocked by CSP. Native code validates message shape and
generation, bounds outgoing queues and incoming WebSocket messages, and awaits
delivery of each receive chunk. Receive chunks are limited to 4 MiB and send
chunks to 64 KiB. Only received changes drive noVNC rendering.
