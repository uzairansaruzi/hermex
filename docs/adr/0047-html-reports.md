# 0047. HTML reports

Area: chat-transcript

## Sandbox agent HTML reports away from app credentials

`HTMLReportWebView` shows one agent-generated HTML page (#1623), shared by the inline transcript row and the sheet. The page runs JavaScript and loads remote resources as a browser would, but reaches nothing of Hermex's: it loads from a string with an opaque origin into a non-persistent data store, so no cookie, credential or custom header of any server is in reach. Camera, microphone, motion, downloads and new windows are refused, the top frame can't navigate (`HTMLReportNavigation`), and tapped links go to the environment's `openURL`. The app's scripts run in their own content world, so the page can't call them or message the app. The view stays transparent until the page has painted, so a dark page never flashes white, and when the web process dies it reloads once, then reports `onFailure`.

Lives in: `HermesMobile/Features/Chat/HTMLReportWebView.swift`

## Scroll report anchors in-app instead of navigating

A report page loads from `about:blank`, and WebKit resolves an anchor like `#notes` against it as a new page, `about:blank%23notes`, so an anchor can't navigate. `HTMLReportNavigation` turns it into an `.anchor` the app scrolls to instead.

Lives in: `HermesMobile/Features/Chat/HTMLReport.swift`

## Measure short report pages by their elements

`HTMLReportWebView`'s measuring script reads the page's content height after two frames, so script-drawn content has laid out. `scrollHeight` never reports less than the view, so a page shorter than the view is measured from its elements instead.

Lives in: `HermesMobile/Features/Chat/HTMLReportWebView.swift`
