# 0135. Session search

Area: sessions

## Collapse JSON escapes in search excerpts

The server previews the raw stored message text, so an excerpt from a serialized tool result arrives carrying that JSON's escapes, such as `...0% /\n---\nRAM: 8.0 GB", "exit_code": 0,...`. `SessionSearchExcerpt` turns those two-character escapes into spaces and collapses whitespace runs so the line reads. A Windows path (`C:\new`) is the accepted false positive: the excerpt is a truncated preview never used as data, and guessing whether an excerpt "is JSON" misfires in both directions.

Lives in: `HermesMobile/Features/SessionList/SessionSearchExcerpt.swift`

## Don't fold diacritics when bolding search hits

The excerpt bolds every occurrence of the query, or a Hermes snippet's marked matches. Matching is case-insensitive over `String` ranges, so composed and decomposed spellings match each other and the bolded range is the text's own, not the query's length. Diacritics are not folded: the server matched the query literally, so folding would bold a span the server never treated as the hit. When redaction has replaced the match, nothing is bolded and the plain excerpt still shows.

Lives in: `HermesMobile/Features/SessionList/SessionSearchExcerpt.swift`

## Exclude the list's hidden sources from Hermes session search

`HermesREST`'s session search excludes the same sources the session list leaves out, so a search never finds a row the list never shows.

Lives in: `HermesMobile/Networking/Hermes/HermesREST.swift`

## Hide group room sessions from lists and search

A group room's session (#1127) is hidden and titled `Group: <room id>`, or Desktop's older `Group: <name> · …`. No screen lists or opens one (#1146): the host refuses a prompt into a room it runs (4122), and a regular chat on a Desktop room would fall out of step with it. A search result carries no `hidden`, so there the title alone tells, and `HermesSessionListTests` covers that a room session is never a search match.

Lives in: `HermesMobile/Networking/Hermes/HermesSessionPage.swift`, `HermesMobileTests/HermesSessionListTests.swift`
