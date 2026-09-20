# Push notifications

Push is optional and off until the user enables it for a server from the Hermes
connection screen. This page is the map. `bots.md` ("Push provisioning" and
"Push previews and taps") owns the protocol detail.

## Components

- **Plugin.** `hermex-push` runs on the user's Hermes host (installed from
  `uzairansaruzi/hermex-push`). It watches the agent, seals each notification's
  text with AES-256-GCM, and posts the event to the relay. Tool arguments and
  results never leave the host.
- **Relay.** A Cloudflare Worker in the same repository. The default is
  `https://hermex-relay.hermex-relay.workers.dev`; a host overrides it with
  `HERMEX_PUSH_RELAY_URL`, so self-hosting is a server-side setting. The relay
  stores a hash of the install key plus the device tokens, and forwards events
  to APNs. It sees device tokens, the notification kind, a coarse source (bot,
  webui, other), a subagent flag, thread and collapse ids, the raw agent
  session id, and timestamps. Progress events add a status, the tool's name,
  and a call count. Title, subtitle, body, profile name, and request id stay
  inside the sealed blob, which the relay cannot open.
- **App.** `HermesMobile/Push/` provisions the host, stores the pairing,
  registers the device token with every paired relay, and routes taps.
- **Notification Service Extension.** `HermesNotificationService` opens the
  sealed preview on device with the preview key and rewrites the banner. On
  any failure the banner stays content-free.

## Where the keys live

- The plugin's key pair stays on the host in `plugin-data`, so reinstalling
  the plugin cannot unpair a phone.
- On the phone, each server's `PushPairing` (relay URL, install key, preview
  key) is one Keychain item in the access group shared with the extension,
  keyed `pushPairing::<server URL>`. The install key is a bearer capability:
  it never appears in a log, a printed URL, or `UserDefaults`.
- The extension reads the same group with `SecItemCopyMatching` and finds the
  right key by matching the payload's `install_hash` against each stored
  `sha256(install_key)`.

## Isolation rule

Pairing is per configured server, and everything derived from a pairing stays
with that server. The device token registers with each paired relay
independently, a tap resolves its server through the pairing, and removing a
server wipes its keys (`PushRegistrar.forget`). Nothing one server's push
touches may show up under another.
