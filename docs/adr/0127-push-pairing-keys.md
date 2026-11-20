# 0127. Push pairing keys

Area: push

## Store push pairings in the shared Keychain access group

A push pairing (relay URL, install key, preview key) is the one credential that lives in a Keychain access group shared with the Notification Service Extension; every other credential stays in the app's default group. The extension finds the right server's preview key by hashing each stored install key and matching the payload's `install_hash`, so it must enumerate the group, which is why `KeychainPushPairingStore` offers `allPairings` and the extension reads it through `PushPreviewKeys.stored`. Moving pairings into the default group leaves the extension unable to unseal any preview.

Lives in: `HermesMobile/Auth/KeychainStore.swift`, `HermesMobile/Push/PushPairing.swift`

## Keep the push install key in the Keychain only

`PushPairing` holds where a server's relay lives, the capability that addresses its install, and the key that unseals its previews. The install key is a bearer capability: whoever holds it can manage that install's devices. It lives in the Keychain and never in a log, a URL that is printed, or `UserDefaults`.

Lives in: `HermesMobile/Push/PushPairing.swift`

## Never log relay URLs

The relay is a different host from the user's Hermes server and speaks a tiny contract of its own, so `PushRelayClient` does not go through `Endpoint` or `APIClient`; its shapes come from `relay/README.md` and `relay/src/contract.ts` in `uzairansaruzi/hermex-push`. The install key sits in the URL path, so no URL built there is ever logged, attached to an error, or shown to the user.

Lives in: `HermesMobile/Push/PushRelayClient.swift`

## Read the Hermes pairing route only after Move is confirmed

`MovePushPairing.carry` carries a webui server's push pairing to the Hermes server it moved to (#1215). It is the Move runner's first step after the commit (#1216) and runs only after the user confirmed Move, because `readDestination` signs in and reads the Hermes host's pairing route, which can create the host's keys; Review never calls it. It copies only when the host confirms the install the webui server is paired with and the Hermes server has no pairing of its own, so a cross-host move copies nothing and never touches the destination's keys.

Lives in: `HermesMobile/Push/PushPairing.swift`
