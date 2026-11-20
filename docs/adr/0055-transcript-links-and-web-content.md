# 0055. Transcript links and web content

Area: chat-transcript

## Send only http(s) links to SafariView

`InAppBrowserPolicy.opensInApp` decides which links go to `SafariView` (the app that claims the page, else the in-app browser) instead of the system: web pages only. Mail, phone, and app links keep going to the system. `SFSafariViewController` raises for any scheme but `http(s)`, so every presentation checks this first.

Lives in: `HermesMobile/Features/Chat/InAppBrowserPolicy.swift`, `HermesMobile/Features/Chat/SafariView.swift`

## Present in-app Safari through UIKit, not a SwiftUI sheet

`SafariView` opens a web page in the app that claims it (a Universal Link, such as a Gmail thread) when one is installed, and otherwise in `SFSafariViewController`, presented through UIKit as a sheet over whatever is on screen, including another sheet (#1619). A SwiftUI `.sheet` inside `transcriptLinks` made every link reader re-run on each owner pass, which `ChatTranscriptEnvironmentStabilityTests` guards. The controller dismisses itself.

Lives in: `HermesMobile/Features/Chat/SafariView.swift`

## Open sign-in and billing links in the system browser

`HermesTurnOutcomeRow` opens a provider's billing page in Safari, not an in-app sheet, as for connector links (#770), because the provider sign-in lives there. It is opened directly, past the transcript's link router.

Lives in: `HermesMobile/Features/Chat/HermesTurnOutcomeRow.swift`

## Parse file references after the transcript's URL round trip

The transcript renderer builds a `URL` from a link destination, and the chat handler reads back `absoluteString`, which percent-encodes spaces and keeps positions and fragments. `FileReference` parsing must accept what comes out of that trip, not only the text the agent wrote.

Lives in: `HermesMobile/Features/Workspace/FileReference.swift`, `HermesMobileTests/FileReferenceTests.swift`

## Block script-driven navigation in inline HTML reports

`HTMLReportNavigation.decision` cancels a main-frame navigation that is not a link tap once the page has loaded, so a script in an agent's HTML report can't move the page, to the web or back to a blank page.

Lives in: `HermesMobile/Features/Chat/HTMLReport.swift`, `HermesMobileTests/HTMLReportTests.swift`

## Scroll to in-page anchors instead of navigating in HTML reports

WebKit hands an in-page anchor tap over as a new page, so `HTMLReportNavigation.decision` maps it to an anchor and the app scrolls to it instead of navigating.

Lives in: `HermesMobile/Features/Chat/HTMLReport.swift`, `HermesMobileTests/HTMLReportTests.swift`
