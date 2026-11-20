# 0101. webui URL encoding and number decoding

Area: networking-webui

## Percent-encode + in query strings

The server reads a `+` in a query as a space, and `URLComponents.queryItems` leaves it literal. `Endpoint.url` replaces `+` in the percent-encoded query with `%2B`, so a value containing `+` arrives unaltered.

Lives in: `HermesMobile/Networking/Endpoints.swift`

## Percent-encode dots in path segments

`Endpoint.pathSegmentAllowed` is the RFC 3986 unreserved characters minus `.`, used when a Kanban Card id or board slug goes into a URL path. Encoding dots keeps the special `.` and `..` path segments inert while preserving the exact Card identity after the server decodes the segment.

Lives in: `HermesMobile/Networking/Endpoints.swift`

## Convert lossy doubles to Int with Int(exactly:)

The lossy `Int` decoders use `Int(exactly: value.rounded(.towardZero))` instead of `Int(_:)`, which traps on doubles outside `Int` range, so a huge server value decodes to nil instead of crashing (#62). Truncation toward zero matches `Int(_:)` for values that fit. The string branch applies the same guard to numeric strings.

Lives in: `HermesMobile/Models/ChatMessage.swift`
