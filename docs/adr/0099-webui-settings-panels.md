# 0099. webui profiles, providers, and server update

Area: networking-webui

## Carry single_profile_mode forward across profile switches

The profile switch response has no `single_profile_mode` field. `SessionListViewModel` builds the new `ProfilesResponse` with the last known `isSingleProfileMode` so the Active Profile switcher's visibility does not flap.

Lives in: `HermesMobile/Features/SessionList/SessionListViewModel.swift`

## Hide New Profile in single-profile mode

The server answers 403 to profile creation in single-profile mode, so `DefaultProfilePickerView` hides the New Profile row when `isSingleProfileMode` (#24).

Lives in: `HermesMobile/Features/Settings/DefaultProfilePickerView.swift`

## Dedupe create-profile model options

`CreateProfileSheet.pickerOptions` lists a group's `models` and `extra_models` as the webui form does. The parser does not dedupe across the two, so repeats are dropped to keep `ForEach` identity unique.

Lives in: `HermesMobile/Features/Settings/DefaultProfilePickerView.swift`

## Lowercase new profile names like the webui

The webui lowercases the typed name before validating and submitting. `CreateProfileSheet.trimmedName` mirrors that, so "Work" creates "work" instead of dead-ending validation.

Lives in: `HermesMobile/Features/Settings/DefaultProfilePickerView.swift`

## Drop the default provider id when creating a profile

Mirroring the webui payload, `CreateProfileSheet.create` sends no `modelProvider` when the selected option's provider id is `"default"`, because that is not a real provider selection.

Lives in: `HermesMobile/Features/Settings/DefaultProfilePickerView.swift`

## Normalize provider ids before matching the active provider

`active_provider` comes from config (`model.provider`) while entry ids are canonical slugs. `ProvidersViewModel.normalizedProviderID` trims and lowercases both sides so cosmetic differences do not hide the Active badge.

Lives in: `HermesMobile/Features/Settings/ProvidersViewModel.swift`

## Send the provider with a default-model save

`APIClient.saveDefaultModel` passes the catalog row's provider (`provider_id` from the catalog group) in `DefaultModelRequest` whenever the row names one. Core persists `{model, provider}` atomically and resolves slash-qualified ids like `anthropic/...` through the named provider's route; without it such an id can be persisted through the wrong provider. Verified in source: the compatibility pin (`f1d399b4`, `routes.py`) reads only `body.get("model")` and ignores the extra key, while `set_hermes_default_model` accepts `provider` from upstream `a00b02f` (`api/config.py`). `provider` is optional so a providerless custom-model save still sends the bare `{model}` body, since synthesized `Encodable` omits nil keys.

Lives in: `HermesMobile/Networking/APIClient+ServerPanels.swift`

## Confirm a webui update restart by version change, not reachability

`WebuiServerSettingsModel.waitForServerToReturn` polls the self-restarting server until the restart is confirmed, bounded so a slow or stuck restart never leaves a spinner up. It waits about 2 s before each probe because the server flushes the response and restarts about 2 s later, so an immediate probe could hit the outgoing process. Completion needs proof the restart happened, a changed reported version or an explicit `.upToDate`, not mere reachability; that avoids finalising against the outgoing process or on a transient `stale_check` that still claims a non-zero `behind`, while update-check-disabled servers still converge through the new version. State is refreshed inline rather than through the non-reentrant `load`, so a concurrent load cannot flip it to `.idle` without refreshing.

Lives in: `HermesMobile/Features/Settings/WebuiServerSettingsModel.swift`
