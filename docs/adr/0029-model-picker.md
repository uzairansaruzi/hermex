# 0029. Model picker and model names

Area: chat-composer

## Match model selections by provider and bare id

The webui server prefixes every model of a non-active provider with `@provider:` (`_apply_provider_prefix` in `api/config.py` @ 399cd7ab, verified on the live deployment, where `openai-codex` is active and its models are bare while `@deepseek:` and `@gemini:` ones are prefixed). The same model is therefore spelled differently depending on which provider is active, so a saved default written under one spelling stopped matching the catalog under the other and the picker showed no checkmark at all. `ServerCatalog` compares the bare id without the prefix. A provider named on either side, the prefix included, has to agree, so two providers offering the same bare id can't be confused; the deployment really serves `@gemini:gemini-2.5-flash` and `@google:gemini-2.5-flash` side by side. A selection that names no provider is the active provider's spelling, because the prefix is exactly what the server adds to everyone else, so it never matches a prefixed option, which would tick every provider offering the same bare id.

Lives in: `HermesMobile/Models/ServerCatalog.swift`, `HermesMobileTests/ModelCatalogTests.swift`

## Match in-flight model rows by id and provider

`ModelPickerSheet` shows the spinner for an in-flight commit only on the row whose id and provider both agree with the ones recorded at tap time. After the live overlay replaces the active provider's prefixed cached row with a bare id, two providers can offer the same spelling, and ticking by id alone would spin both rows.

Lives in: `HermesMobile/Features/Shared/ModelPickerSheet.swift`

## Search models by what the picker shows

The picker's search must find what the user sees on screen. A group whose display name matches the query keeps all of its models, so a provider stays findable by the name it is shown under: the id is spelled `openai-codex` where the header reads "OpenAI Codex", and matching only ids would answer "no models". Rows render the prettified label, so searching "GLM 5.3" must match `zai/glm-5.3-flash:local`, not only its raw id.

Lives in: `HermesMobile/Features/Shared/ModelPickerSheet.swift`

## Save the webui server default model as a bare id

The custom entry's `.composer` mode needs both provider and model, because a model selected mid-session is always addressed by provider. `.serverDefault` commits a bare model id with no provider, which is what Settings has always sent. Only the composer prefills the provider field; prefilling it for the server default would quietly turn every bare-id save into a provider-scoped one.

Lives in: `HermesMobile/Features/Shared/ModelPickerSheet.swift`

## Prettify only model ids, never server-provided names

The catalog's `displayName` is the server-provided `name`/`label` when the webui transport carried one and falls back to the raw id otherwise, so exact, case-sensitive equality with the id is the signal that nothing was provided, and only that fallback is prettified. A server name renders verbatim because the server owns that string: prettifying "Team / Production" to "Production", or "Qwen-Max" (differing from `qwen-max` in case alone) to "Qwen Max", would rename someone else's model. This is display only: matching by id, favorites, and the `--session` string never see it.

Lives in: `HermesMobile/Models/ModelDisplayNames.swift`

## Keep the full GGUF quant in model tags

The tag keeps the quant's full component: `Q4_K_M` and `Q4_K_S` are different files the picker shows side by side with no raw id beside the label, so truncating to the family would render both as `Q4`. The `UD-` uploader prefix stays too, because it names a distinct build.

Lives in: `HermesMobile/Models/ModelDisplayNames.swift`
