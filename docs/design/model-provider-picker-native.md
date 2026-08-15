# Native model and provider picker design

Status: implemented on the native picker feature branch; live simulator visual
review and tests are recorded separately.

This document replaces the earlier AI-generated raster mockups as the
implementation reference. Those phone concepts were generated as PNG/JPEG
images and then arranged and labeled with collage scripts. The only SVG produced
in that exploration was the generic provider fallback artwork; the screens
themselves were not SVG layouts, SwiftUI previews, or simulator captures.

The raster mockups were useful only for discussing information architecture.
They did not use Hermex's real SwiftUI components, typography, palette, spacing,
materials, data, or runtime behavior and must not be treated as visual acceptance
artifacts.

The implementation reference will be a real SwiftUI prototype built in this
repository and captured from the signed iOS Simulator in both light and dark mode.

## Outcome

Replace the current vertically dense `ComposerModelPickerSheet` with one native
picker that makes four tasks clear:

1. Find a model by search.
2. Choose the model view: All, Favorites, or Recent.
3. Scope results to a provider.
4. Select or favorite a model without exposing the custom-model form all the time.

Provider presentation can also be customized through a native long-press menu,
but presentation changes must remain separate from provider routing and secrets.

## Non-negotiable identity rules

### Provider display name and provider ID are different values

Never combine, overwrite, or use these interchangeably:

- `providerID` is the immutable technical identity used for routing, catalog
  matching, requests, favorites, recents, and persistence. Examples include
  `openai-codex` and `kimi-coding`.
- `displayName` is presentation text. It may come from the server or from a local
  user override, and it may be edited or reset without changing routing.

The provider editor must show both values:

- **Display Name**: editable.
- **Provider ID**: visible, selectable/copyable if useful, and read-only. Include
  the explanation: “Routing identity can’t be changed.”

Changing a display name must never rewrite `providerID`, model IDs, session
configuration, request bodies, favorite keys, recent keys, or server config.

Provider presentation overrides must be scoped by `(serverAccountID, providerID)`.
The same slug can represent different custom services on different Hermex servers.

### Model display name and model ID are also different values

Preserve the existing `ModelCatalogOption` separation:

- `displayName` is readable UI text.
- `id` is the exact server model identifier.
- `providerID` disambiguates identical model IDs exposed by different providers.

Never normalize or reconstruct a model ID from its display name. Favorites and
recents must continue using `ModelFavoriteKey(modelID, providerID)`.

Custom model entry must keep **Exact Model ID** and **Provider ID** as separate
fields. Do not concatenate them into one editable “provider:model” field unless a
server-supplied model ID already uses that exact form.

## Unified information architecture

Use a native sheet with `NavigationStack`, Hermex palette surfaces, Dynamic Type,
and the existing adaptive medium/large presentation.

Top-to-bottom hierarchy:

1. Native title and Done action.
2. Search field: “Search providers & models.”
3. Model-view segmented control: **All**, **Favorites**, **Recent**.
4. Provider scope control beginning with **All Providers**, followed by provider
   cards from the current model catalog.
5. A heading that describes the current result, such as “OpenAI Codex Models,”
   “Favorite Models,” or “Recent Models.”
6. Native model rows with selection state, display name, optional exact ID/provider
   metadata, and a trailing favorite button.
7. A secondary **Add Custom Model** action that opens a separate entry sheet.

The custom-model fields must not permanently occupy the top of the main picker.

### Two independent axes

`All / Favorites / Recent` is a model-view filter, not a provider selector and not
one mixed chip list. Provider cards independently scope whichever model view is
active.

Recommended state behavior:

- **All** initially scopes to the current model's provider.
- **Favorites** initially scopes to All Providers so cross-provider shortcuts are
  immediately useful.
- **Recent** initially scopes to All Providers and orders models most-recent first.
- Each model view remembers its last provider scope while the sheet remains open.
  Switching back restores that view's scope instead of resetting all controls.
- Tapping a provider changes scope only. It does not select a model.
- Tapping a model selects it, records it in recents, and dismisses the sheet, as
  the current picker does.
- Tapping a star changes favorite state without selecting or dismissing.

The compact composer menu can keep de-duplicating favorites from its Recent
section. In the full picker, the Recent view should show all recent models,
including starred ones, with their filled favorite state visible; mutually
exclusive tabs already prevent duplicate rows on one screen.

### Ordering and search

- All: preserve server catalog order within the selected provider.
- Favorites: preserve the user's saved favorite order.
- Recent: preserve MRU order from `ModelRecentsStore`.
- Provider cards: preserve `/api/models` group order, with All Providers first;
  scroll the active/current provider into view rather than silently reordering.
- Search matches provider display name, provider ID, model display name, and exact
  model ID.
- If the provider name matches, include that provider's models.
- If only individual models match, retain their provider card and show the match
  count/result.
- Search filters the current model view and provider scope; clearing search
  restores both without losing selection.

Provide native loading, empty, error, offline, no-favorites, and no-recents states.
Do not render empty provider disclosures.

## Which providers belong in this picker

`GET /api/providers` currently reports every known/configurable provider. The
live server audit on 2026-08-12 returned 53 entries, including providers with no
selectable models. Showing all of them would turn the model picker into a settings
catalog.

The picker provider set must therefore come from `GET /api/models` catalog groups.
Those groups are authoritative for selectable models. Join `/api/providers` by
immutable `providerID` only to add status or server display metadata when useful.

The Settings Providers screen remains the place to inspect every known provider.

## Provider artwork

### Current capability

The 2026-08-12 audit found:

- No provider-specific images in the Hermex iOS asset catalog.
- No provider artwork bundled in the upstream WebUI.
- No `icon`, `logo`, `thumbnail`, SVG, or image URL field in the live
  `GET /api/providers` response.

Therefore the current server-supplied provider-thumbnail count is zero.

### Artwork resolution order

Resolve artwork in this order:

1. Per-server user artwork override.
2. Vetted brand artwork bundled with Hermex.
3. The bundled Hermex provider fallback artwork.

Never fetch provider artwork from a CDN at runtime. Bundling avoids tracking,
offline failures, remote changes, and inconsistent light/dark rendering.

Candidate brand SVG coverage found in the maintained Simple Icons catalog includes
Anthropic, Gemini/Google, Kimi/Moonshot, Meta, DeepSeek, Qwen, Hugging Face,
Mistral, NVIDIA, Ollama, OpenRouter, GitHub Copilot, LM Studio, Alibaba Cloud,
Google Cloud/Vertex, MiniMax, Cursor, and Xiaomi. Each asset still requires a
source, license, trademark, and light/dark review before inclusion.

OpenAI/Codex and Fireworks use the Hermex fallback because no redistributable
artwork with sufficiently reproducible licensing provenance was identified.
VibeProxy and many plugin providers likewise lack a vetted mapping. There are no
provider-logo network calls at runtime.

### Fallback artwork

Use the custom Hermex vector at:

`docs/design/assets/provider-fallback.svg`.

This checked-in SVG also ships in the Xcode asset catalog as `ProviderFallback`.
Its light/dark rendering has been reviewed in the real app.

The fallback is a tintable, single-color network/hexagon symbol. It deliberately
does not draw text inside the thumbnail; the adjacent provider name carries the
identity. A stable provider-derived color maps onto a small approved palette and
is not the only identifier.

Bundled SVGs can be compiled through the asset catalog. Arbitrary user-supplied
SVG is a separate implementation problem: SwiftUI does not natively render every
runtime SVG safely, and this project cannot add a third-party dependency without
approval. Initial custom-artwork support should accept native image formats from
Photos/Files. Runtime SVG import requires a bounded renderer/security spike before
it is promised as shipped behavior.

## Provider long-press interaction

Apply a native context menu to each provider card. The preview must remain
spatially anchored to the pressed card, use immediate press feedback, and remain
accessible through an explicit alternative action for VoiceOver/switch-control
users.

Recommended actions:

1. **Edit** — opens the provider editor.
2. **Set Current Model as Default** — conditional. Show only when the current
   model belongs to this provider and its exact server identifier can be sent
   unambiguously through the verified default-model API. Do not create a
   provider-only default concept the server does not support.
3. **Refresh Models** — conditional on an authorized, implemented client endpoint.
4. **Reset Appearance** — show only when a local name or artwork override exists.

Do not include Delete in the picker context menu. Removing credentials or a
provider is operational and potentially destructive; it belongs in provider
settings with the server's existing confirmation/ownership rules.

## Provider appearance editor

Open a native form sheet titled “Edit Provider.”

Fields and actions:

- Artwork preview.
- Name: an obvious editable local override with a plain explanation of where it appears.
- Image: one attachment-style **Choose Image** menu for Photos, Files, and restoring the bundled default.
- Provider Details: collapsed by default, with Provider ID as read-only technical identity.
- Restore Defaults: stages the original name and bundled artwork, then applies them on Save.
- Manage Connection & Models: navigates to the existing provider-settings/status
  surface rather than duplicating credential controls in this editor.

Use “Fallback,” not “Generated.” The fallback is deterministic and offline; it is
not AI-generated at runtime.

Save local presentation metadata in `UserDefaults` or another small preference
store, keyed by `(serverAccountID, providerID)`. Store imported image bytes in an
app-owned Application Support directory and keep only a safe relative reference
in preferences. Never put API keys, authentication tokens, remote headers, or
other secrets in this store.

Recommended display-name precedence:

1. Local display-name override.
2. `/api/providers.display_name` joined by `providerID`.
3. `/api/models` group name.
4. A readable formatting of immutable `providerID`.

## Provider-management boundary

The current iOS `ProvidersView` is deliberately read-only. It loads provider
status, authentication source, errors, and models, but it does not write provider
configuration.

The audited WebUI supports:

- Standard configurable providers: save/remove API key and refresh models.
- Self-hosted providers such as Ollama and LM Studio: Base URL, optional API key,
  model ID, connection test, save/remove, and refresh.
- Config-defined custom providers: status only; the WebUI tells the user to edit
  the CLI/config file.

The upstream server does not currently expose provider display-name or artwork
writes. Those are Hermex-local presentation overrides unless a future server API
is explicitly designed.

Do not silently add WebUI mutation endpoints to the iOS client during the picker
work. Adding API-key, Base URL, model configuration, connection testing, refresh,
or removal to iOS is a separate provider-management feature. It requires a
PROJECT_SPEC update, endpoint verification against the live server, secret-safe
storage/input handling, tests, and explicit destructive-action UX.

## Native visual implementation

The prototype must reuse the app, not imitate it:

- SwiftUI system typography and Dynamic Type.
- `ChatPalette.appChrome` and `appSurfaceBackground` roles.
- Existing `ChatTactileButtonStyle` where appropriate.
- Native `NavigationStack`, sheet presentation, segmented picker, context menu,
  buttons, search behavior, focus, and accessibility semantics.
- Continuous corners and spacing consistent with the current composer and
  settings surfaces.
- Minimum 44-point interactive targets.
- Selected, current, and favorite states distinguished by icon and text/shape,
  not color alone.
- Reduced Motion, Reduced Transparency, increased contrast, and accessibility
  Dynamic Type behavior.

Avoid external brand-logo network calls, decorative gradients, generic SaaS
cards, fabricated capability tags, and custom controls that only resemble iOS.

## Implementation sequence

### 1. Real SwiftUI picker prototype

- Refactor `ComposerModelPickerSheet` around model-view state and provider scope.
- Reuse existing model selection, favorites, recents, search, live catalog merge,
  and custom-model behavior.
- Add an All Providers scope without losing exact provider-aware identity.
- Keep the existing compact composer menu behavior unless intentionally changed
  and separately tested.

### 2. Provider presentation registry

- Add the per-server/provider presentation key and preference store.
- Add bundled, vetted artwork mappings.
- Add the deterministic fallback asset and resolver.
- Join optional `/api/providers` presentation/status metadata by `providerID`.

### 3. Native management interaction

- Add provider-card context menus.
- Add the appearance editor and reset behavior.
- Add custom native-image import with storage cleanup/replacement tests.
- Defer arbitrary SVG import until its rendering/security spike passes.

### 4. Optional operational integration

- Add only the provider-management actions approved in PROJECT_SPEC.
- Verify every endpoint and payload against the live server before coding.
- Keep destructive credential/provider actions out of the model picker.

## Verification and acceptance

AI-generated UI images are not acceptance evidence.

Required code verification:

- Unit tests for model-view/provider-scope combinations.
- Search across provider name/ID and model name/ID.
- Favorites and recents remain keyed by exact `(modelID, providerID)`.
- View-specific provider scope restoration.
- Display-name precedence and reset behavior.
- Artwork precedence, fallback stability, per-server isolation, missing-file
  recovery, and imported-image cleanup.
- Custom-model provider/model separation.
- Loading, empty, error, stale/offline, and disappearing-model behavior.
- VoiceOver labels, values, hints, and non-context-menu access to edit actions.

Required runtime verification:

- Run the full XCTest suite.
- Build and launch a signed Debug app on the configured iPhone simulator.
- Exercise the picker against the real server catalog where possible.
- Use XCUITest for taps and long presses if host synthetic clicking is unreliable.
- Confirm medium and large detents, keyboard/search, Dynamic Type, light/dark mode,
  and narrow/large device layouts.

Required visual evidence must consist only of actual simulator screenshots:

1. Current picker, light and dark.
2. Unified picker, light and dark.
3. Provider long-press menu, light and dark.
4. Provider appearance editor, light and dark.

Assemble those screenshots into before/after collages only after the prototype is
running. The collage process may crop and label screenshots, but must not redraw,
generate, or cosmetically replace the application UI.

## Decisions deliberately deferred

- Arbitrary runtime SVG import and its safe renderer.
- Whether provider appearance overrides should eventually sync through the server.
- Full writable provider management in iOS.
- New third-party icon or SVG-rendering dependencies.
- Provider/model capability badges, because the current catalog does not expose a
  verified capability contract for them.
