# 0142. Hermes connection credentials

Area: settings-onboarding-auth

## Send the open dashboard's token as X-Hermes-Session-Token

An open dashboard's session token comes from its page (`HermesREST.pageToken(in:)`) and is sent as `X-Hermes-Session-Token`, never `Authorization`, which a proxy's basic auth may hold.

Lives in: `HermesMobile/Networking/Hermes/HermesConnection.swift`

## Prove an open dashboard's token with a gated read

For an open dashboard's page token, any gated read proves the token. `/api/auth/me` is not used: at the 0.21.5 pin it answers 401 in this mode, since only the password gate sets a session.

Lives in: `HermesMobile/Networking/Hermes/HermesConnection.swift`

## Do a gated read before a socket upgrade

The upgrade `build` makes is returned for a fresh pass with this connection's headers, and either pass is preceded by a signed-in read, so a 401 signs in again first: minting the ticket, or for a page token a gated read. This matters because a refused upgrade can't tell a token a host restart replaced from any other refusal. `recordsLiveStages` starts the attempt record's live stages afresh and records the pass, for the gateway's socket only, never a Kanban socket's.

Lives in: `HermesMobile/Networking/Hermes/HermesConnection.swift`

## Never lose a rotated refresh token

The host retires the sent refresh token as soon as it rotates it, so the rotated one must be saved before the new access token is used, even when the connection was retired meanwhile; `HermesConnections` saves it. The exchange and the save run in `refreshInFlight`, which retiring the connection never cancels: once the host has the request it may already have rotated the token, and only its reply saves the new one. A fresh connection starts each refresh from the token saved for it when that changed since it last looked, once any refresh a retired connection on the same server still has in flight has saved its own; that refresh is looked up at each refresh, not when the fresh connection is made, since a connection beside it can be retired later (#1265). A save only replaces the token this connection last saw saved, so a record removed or signed in again keeps what it has, and a failed save is retried at the next rotation from the token in memory. A 401 on the exchange means the host no longer accepts the refresh token (`.signInExpired`); any other refusal is `.rejected` and leaves the token for the next sign-in.

Lives in: `HermesMobile/Networking/Hermes/HermesConnection.swift`
