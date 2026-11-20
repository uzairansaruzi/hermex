# 0141. Default model picker

Area: settings-onboarding-auth

## Match the default model checkmark through matchesSelection

`DefaultModelPickerView.isChecked` compares rows through `ModelCatalogOption.matchesSelection`, which normalizes the `@provider:` prefix the server adds to models outside the active provider. A raw `==` left the checkmark off every row whose saved spelling differed from the catalog's current one, so the picker could not answer "which one am I on" at all. The stored default is matched against the provider its own spelling names, an embedded `@provider:` prefix staying authoritative, and falls back to `activeProvider` for a bare id, which belongs to whichever provider is active. Without that fallback, Core's catalog dedup can prefix the active provider's own rows while an inactive provider keeps the bare spelling, and the wrong row ticks.

Lives in: `HermesMobile/Features/Settings/DefaultModelPickerView.swift`

## Let an in-flight tap own the checkmark

While a save is in flight, `isChecked` matches only against the provider captured at tap time, so only the tapped row announces "Selected"; OR-ing the previous default would leave two rows announcing "Selected" until the save finishes. A custom or providerless save names no catalog row, and matching with `providerID: nil` would tick every bare same-id row after the live overlay, so the catalog stays unchecked and the custom button owns the spinner via `isSavingCustom`.

Lives in: `HermesMobile/Features/Settings/DefaultModelPickerView.swift`

## Detect a stored provider prefix without splitting on the last colon

A stored `@provider:` spelling must not be pre-split with `lastIndex(of: ":")`, which turns `@ollama:qwen3:32b` into provider `ollama:qwen3`. `isChecked` detects the prefix by whether one exists at all (`modelIDProviderPrefix`); `@cf/meta/...` model ids start with `@` but have no colon, so they stay bare and match against `activeProvider`. Passing nil then lets `matchesSelection` use the row's own `providerID` as the prefix key.

Lives in: `HermesMobile/Features/Settings/DefaultModelPickerView.swift`
