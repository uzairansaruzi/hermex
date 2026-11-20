# 0095. APIClient custom headers, redirects, and sessions

Area: networking-webui

## Send custom headers only to same-origin requests

The user's custom headers may be secrets, such as an `Authorization` bearer for a reverse proxy. `APIClient.downloadData` applies them only when the URL is same-origin with the server's `baseURL`, which includes the user's own server fetched through the cookie-less `publicMediaSession`, since that media traverses the proxy. `downloadData` also fetches external third-party transcript images, and those must never receive the headers, or they leak off-origin (#255).

Lives in: `HermesMobile/Networking/APIClient.swift`, `HermesMobileTests/CustomHeaderInjectionTests.swift`

## Apply built-in headers after custom headers

`APIClient` and `SSEClient` set their built-in headers (`Accept`, the multipart `Content-Type`, `text/event-stream` for SSE) after the user's custom headers, so the built-in value wins its key. A user-supplied header of the same name, such as `Accept`, never overrides them (#255).

Lives in: `HermesMobile/Networking/APIClient.swift`, `HermesMobileTests/CustomHeaderInjectionTests.swift`

## Strip custom headers on cross-origin redirects

`APIClient` only attaches custom headers to same-origin requests, but when the server answers one with a 3xx to another host, `URLSession` forwards those headers by default. `URLSession` already strips `Authorization` and a few sensitive headers, so the residual leak is a non-`Authorization` custom header such as `X-Api-Key`, which may be a secret. `CrossOriginHeaderStripper` closes that gap (#277): same-origin redirects keep the headers, because a proxy path rewrite still needs them, and a request with no custom headers is left byte-identical. It implements only `willPerformHTTPRedirection`, so TLS trust and auth challenges keep `URLSession`'s default handling; it is `nonisolated` so tests drive the exact delegate the client installs.

Lives in: `HermesMobile/Networking/APIClient.swift`

## Refuse a cross-origin redirect of anything but GET or HEAD

A 302 or 303 turns the request into a bodiless GET, but a 307 or 308 resends the method and body, which can carry a password or token. `CrossOriginHeaderStripper` therefore refuses a cross-origin redirect of any other method, such as a POST, and the caller gets the 3xx instead of the body reaching another origin (#277). Same-origin redirects, like a proxy's trailing-slash 307, are still followed.

Lives in: `HermesMobile/Networking/APIClient.swift`, `HermesMobileTests/CustomHeaderInjectionTests.swift`

## Clear redirected headers one at a time with setValue(nil:)

`CrossOriginHeaderStripper` removes each matching header from the redirected `URLRequest` by its real, original-case name with `setValue(nil, forHTTPHeaderField:)`. Reassigning `allHTTPHeaderFields` with a filtered dictionary does not work: that setter merges new keys instead of deleting omitted ones, so nothing would be dropped.

Lives in: `HermesMobile/Networking/APIClient.swift`

## Share the process-wide sessions and guard redirects per task

`APIClient` instances share the process-wide URL sessions, one connection pool per host even across servers, instead of each opening a cold one (#688). Those sessions have no delegate, so each client builds one `CrossOriginHeaderStripper` from its origin and header provider and attaches it as the per-task delegate on every request (#277).

Lives in: `HermesMobile/Networking/APIClient.swift`, `HermesMobileTests/CustomHeaderInjectionTests.swift`

## Give the Move to Hermes copy client its own cookie jar

`APIClient.moveCopyClient` builds a client with a cookie jar of its own, seeded with the source server's sign-in. A Profile switch sets a Profile cookie, so the copy's switches never reach the shared jar the app's screens use, and no screen's switch reaches the copy's jar. `URLProtocol` fixtures never see cookies, so the tests check the jar directly.

Lives in: `HermesMobileTests/MoveToHermesTransferTests.swift`
