# 0126. Push device registration

Area: push

## Derive the APNs environment from APS_ENVIRONMENT

The relay must be told the device token's true APNs environment: Apple rejects a token registered under the wrong one and the relay then revokes the device, which looks like push silently stopped working. `PushEnvironment` is not derived from the bundle suffix, since Branch TestFlight is a production build, but from `APS_ENVIRONMENT`, the one project-level build setting in `HermesMobile.xcodeproj` that writes both the `aps-environment` entitlement (`HermesMobile.entitlements`) and the `HermesAPSEnvironment` key in `Info.plist`: `development` for Debug, `production` for Release. Only export re-signing could make the two differ, and nothing checks the uploaded app: both upload paths (`release-candidate-testflight.yml`, `scripts/branch-testflight`) archive Release and export straight to App Store Connect.

Lives in: `HermesMobile/Push/PushEnvironment.swift`

## Re-register the device token on every launch

`PushRegistrar` owns this device's APNs registration across every paired server. One phone has one device token but may be paired with several servers, each with its own install at possibly its own relay, so every token change is reported to all of them. Registration is never requested before a pairing exists, so an unpaired user is never prompted and never mints a token; once one exists, the token is re-registered on every launch, because the relay revokes a device on its own when Apple reports the token invalid and a past registration cannot be assumed to still hold.

Lives in: `HermesMobile/Push/PushRegistrar.swift`

## Send confirmed preferences on every device registration

The relay replaces a device's preferences whenever it is registered, including the launch refresh and token rotation. `PushRelayClient.registerDevice` therefore always sends the server's confirmed choices (`effectivePreferences`); a registration without them would reset the user's preferences on the relay.

Lives in: `HermesMobile/Push/PushRelayClient.swift`

## Serialize push device writes on one queue

Preference writes, token refreshes, and teardowns share one queue (`enqueueRegistrationWork`). A delayed refresh must never replace a newly accepted choice with an older snapshot, and a teardown judges which entries hold a token only once no write to them is in flight (#1178).

Lives in: `HermesMobile/Push/PushRegistrar.swift`

## Journal push preference changes before calling the relay

`updatePreferences` first saves the pairing with `preferencesNeedSync` set, before it changes the relay. If the Keychain is unavailable the relay is left unchanged, and if the process ends partway, reload can still reconcile the relay with what was stored.

Lives in: `HermesMobile/Push/PushRegistrar.swift`

## Undo a relay registration whose keys failed to save

In `enable`, the relay has already accepted the device by the time the pairing is saved. If that save fails there are no keys on disk, so nothing could ever revoke the device; the registrar retires the registration before reporting the failure rather than leave a phone that cannot be unpaired.

Lives in: `HermesMobile/Push/PushRegistrar.swift`

## Delete the relay device before wiping keys on disable

`disable(for:)` removes the device from the install's relay first and only then wipes its keys. Dropping the install key while the relay still holds the device would leave a phone that keeps buzzing with no way left to address it. A failure throws and changes nothing, so the user can retry; like `forget`, it leaves a device that another entry for the same host still uses.

Lives in: `HermesMobile/Push/PushRegistrar.swift`

## Forget push keys even when the relay is unreachable

`forget(for:)` is the teardown for a connection or server the user removed, and unlike `disable(for:)` it never fails: the keys go whether or not the relay could be told, because the user has already thrown the connection away and an unreachable relay must not leave credentials behind. The relay drops the device on its own once Apple reports the token invalid. A device another entry for the same host still uses stays registered, and so does one when the Keychain cannot say whether another entry uses it.

Lives in: `HermesMobile/Push/PushRegistrar.swift`
