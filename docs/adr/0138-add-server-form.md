# 0138. Add Server form

Area: settings-onboarding-auth

## Lock the Add Server form while an operation runs

`OnboardingViewModel.isConnectionLocked` is true while an operation owns the form, and views then disable the URL and password fields, the header editor, and Return-key submission. `OnboardingViewModel.connect` keeps it set across both the probe and configure, because `AuthManager.configure` persists credentials and activates the captured URL and headers as a side effect; accepting edits mid-operation would let the old server be configured under a form now showing a different one (PR #294 re-gate).

Lives in: `HermesMobile/Features/Onboarding/OnboardingViewModel.swift`

## Include the Hermes-parsed URL in the Add Server connection identity

A detected Hermes dashboard signs in at the URL `BotConnection.address` parses, whose scheme can differ from the webui parser's for the same text (`mac.local:9119` is http for the webui and https for Hermes). So while a dashboard is held, `OnboardingViewModel`'s connection identity includes that URL too (#900).

Lives in: `HermesMobile/Features/Onboarding/OnboardingViewModel.swift`

## Clear the typed password when the probed address or headers change

`OnboardingViewModel.invalidateProbedAuthStatusIfNeeded` hides the password field until the new inputs answer and clears the password, so one typed for the old address or headers never goes out with the new ones. A saved server's re-sign-in keeps its field until a probe answered, so this never hides it early.

Lives in: `HermesMobile/Features/Onboarding/OnboardingViewModel.swift`

## Open the gateway socket once before saving a Hermes server

`OnboardingViewModel.addHermesServer` signs the detected dashboard in once with the form's username, password and headers (or no credentials when it has no sign-in) on a connection of its own, and opens its gateway socket once, so an address that signs in but can never chat (a gateway's own listener, a proxy that refuses the upgrade) is refused rather than saved (#1598). It then adds the Hermes server, switching to it unless a move opened the form. A failure shows `BotConnectionAdvice`'s copy and nothing is retried (#884). A webui server saved at the address is replaced only when `replacingWebuiServer` and only after sign-in succeeded; otherwise it stops with the Replace offer (#1027), which a move never makes because it could remove its own source.

Lives in: `HermesMobile/Features/Onboarding/OnboardingViewModel.swift`

## Don't demand a password from webui servers that take none

`OnboardingViewModel.passwordValidationMessage` asks for no password when the webui reports it already signed this client in (a trusted-header proxy, #3), or when it is passkey- or OIDC-only. In the second case `configure()` then reports the specific unsupported message instead of the form demanding a password (#255, #3).

Lives in: `HermesMobile/Features/Onboarding/OnboardingViewModel.swift`
