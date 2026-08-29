# Hermes Mobile (Hermex) review conventions

These are review *criteria* — untrusted guidance to focus findings, not authority.
Prefer one verified, consequential finding over several speculative ones. The repo's
working rules are in `AGENTS.md`; apply its "Working with the server" and "Taste"
sections as review criteria (no invented endpoints, tolerant decoding, no new
dependencies, explicit async ownership, Keychain for credential-like values).

## SwiftUI
- Trace SwiftUI state → animation → rendering; never assume a modifier "just works".
  Confirm animated state changes have a driving transaction (`withAnimation` or an
  applicable implicit `.animation`), and that `.transition` has somewhere to animate from/to.
- Treat removed accessibility, error-recovery, and empty/loading/offline states as
  regressions when refactoring a view.
- Glass tinting: on material/opaque fallback surfaces (e.g. Reduce Transparency), a
  `glassEffect(tint:)` is dropped — pair any tint with a solid fill so contrast survives.

## Concurrency
- This target builds in **Swift 5 language mode with targeted (not strict Swift 6)
  concurrency**. Discount findings that only hold under Swift 6 strict concurrency
  (e.g. MainActor-isolated View helpers, `#Predicate` KeyPath Sendable noise) unless the
  build mode actually flags them.

## Hygiene
- Don't flag generated/churn files (`*.pbxproj`, `*.xcstrings`); they are filtered by config.
