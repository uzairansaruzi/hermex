# Model/provider picker adversarial visual review

Review basis: the generated `unified-light.png` and `unified-dark.png` concept
rasters were compared side-by-side with fresh signed iPhone 17 Simulator captures
of the production SwiftUI sheet. The rasters remain direction-only; the simulator
is the acceptance artifact.

## Blockers found in the baseline and resolved

| Detail | Baseline failure | Implemented resolution |
| --- | --- | --- |
| Sheet height | Medium detent exposed roughly one model and made the hierarchy feel cramped. | Initial detent is 84% with Large still available; four live model rows are visible on iPhone 17. |
| Provider selection | Bright blue outline looked like an unstyled focus ring. | Restrained warm bronze border plus a check badge; selection is not color-only. |
| Provider thumbnails | Repeated generic tiles contained text initials and looked fabricated. | No text inside thumbnails. Vetted SVG marks are compiled into the asset catalog, with a quiet Hermex fallback only where no reviewed mark exists. |
| Provider names | Raw IDs such as `openai-codex` and `kimi-coding` leaked into presentation. | Human-readable local presentation names are resolved separately from immutable provider IDs. |
| Provider cards | Cards were short, visually dense, and clipped long names. | 102x94-point continuous cards, larger 38-point artwork, two-line labels, and model-count captions. |
| Model results | Individual rows resembled default list skeletons and lacked visual grouping. | One warm semantic surface with continuous corners, inset dividers, fixed selection/favorite targets, and stable 64-point rows. |
| Metadata | Exact model ID and provider name were redundantly concatenated while already scoped to one provider. | Scoped results show the exact model ID only. All-provider results add the human-readable provider presentation name without changing identity. |
| Custom model form | Permanent fields competed with discovery. | A quiet bottom action opens a separate native identity form with Exact Model ID and Provider ID kept independent. |

## Detail comparison after refinement

- Typography uses SwiftUI system styles and Dynamic Type rather than raster-matched
  fixed fonts. Title, section label, result title, model title, and metadata have
  distinct weight/contrast roles in both appearances.
- Search and All/Favorites/Recent remain native controls. The two filters are
  independent: model view changes do not select a provider, and provider scope
  does not select a model.
- The warm light canvas, warm dark canvas, surfaces, separators, and text reuse
  `ChatPalette` semantic roles. The bronze state color was chosen specifically to
  match the reference restraint without coupling this control to the user-selectable
  header color.
- Providers without artwork that has verified redistribution provenance, including
  OpenAI/Codex and Fireworks, use the deterministic Hermex fallback. Reviewed
  Simple Icons marks such as Kimi retain distinct silhouettes.
- The native long-press menu stays anchored to the provider card. VoiceOver has an
  explicit Edit action so context-menu discovery is not the only path.
- The editor presents human-readable display name separately from read-only,
  copyable Provider ID. Artwork actions cover Photos, Files, bundled automatic,
  deterministic fallback, and reset without touching connection credentials.
- Favorite stars have 44-point hit targets and do not select/dismiss the sheet.
  Model rows also retain a non-color selection symbol.
- No provider image URL is decoded from the server response and no provider logo
  network request occurs at runtime.

## Intentional deviations from the generated rasters

- The raster's decorative leading plus button was omitted because the persistent
  Add Custom Model action is clearer and avoids duplicate entry points.
- Exact model IDs remain visible because they are operationally important in a
  self-hosted multi-provider app. They are lower contrast and truncated in the
  middle rather than hidden or reconstructed from display names.
- Native iOS search, sheet chrome, segmented control, context menu, and Form are
  retained instead of custom-drawing raster facsimiles. This preserves platform
  accessibility, keyboard behavior, Dynamic Type, and future iOS adaptation.
- Provider cards scroll horizontally instead of forcing four equal-width cards;
  the live server currently exposes ten providers and the control must scale.

## Runtime evidence

- Light and dark before/after collages:
  `docs/design/screenshots/model-picker-before-after-light.png` and
  `docs/design/screenshots/model-picker-before-after-dark.png`.
- Native long-press menu and editor captures were exported from a passing local
  `ModelPickerUITests/testProviderLongPressOffersAppearanceEditor` result bundle;
  that XCUITest target is intentionally absent from the upstream-shaped branch.
- The local deterministic UI test expands **Provider Details** and asserts the
  provider's immutable ID remains visible and unchanged in the editor.

No unresolved visual blocker remains from the baseline comparison. The remaining
review decision is product taste: whether to keep the exact model-ID metadata in
the primary list or reveal it only on demand.

## Independent release-gate review

The final independent review found no P0 issue and two P1s, both resolved before
release:

- Provider image imports now use file-backed Photos/Files transfer, reject inputs
  above 20 MB or 100 megapixels, and downsample through ImageIO to a 512-pixel PNG
  away from the main actor before preview or persistence.
- Provider cards switch to wider, self-sizing horizontal content at accessibility
  Dynamic Type sizes. A deterministic XXXL UI test verifies the selected provider
  remains visible and tappable.

The same pass also removed the no-op **Edit** accessibility action from **All
Providers**, reconciles provider scopes after catalog changes, scrolls the active
provider into view, reports missing custom artwork as the rendered default state,
and replaced live-server-dependent UI tests with a deterministic DEBUG fixture.

## Provider editor second-pass audit

The original editor was structurally safe but read like a developer settings
form. A fresh signed-simulator audit found and resolved these issues:

| Finding | Resolution |
| --- | --- |
| `Identity` led with routing language instead of the user's task. | A clearly labeled **Name** card places the editable field first and explains where the name appears. |
| Four thumbnail actions competed at the same hierarchy. | One full-width **Choose Image** control opens the same native menu pattern as the composer attachment button, with **Photos**, **Choose File**, and contextual **Restore Default Image**. |
| Provider ID looked like a primary editable field. | Technical routing information moved under collapsed **Provider Details** and remains selectable but read-only. |
| Name saved only on Done while image changes saved immediately, so Cancel was misleading. | Name and image are staged in the editor; **Save** commits both and **Cancel** commits neither. |
| An image write failure could leave the new name saved. | The appearance store prepares and writes the image before persisting the combined name/image snapshot; invalid image data leaves the original appearance unchanged. |
| `Choose Image` wrapped inside a narrow trailing capsule. | The chooser became a full-width row beneath the image preview/status. |
| Disclosure tint fell back to system blue. | Technical details use the screen's neutral primary tint. |
| Restore was destructive-looking and visually detached. | **Restore Defaults** is now a quiet, bordered secondary action and applies only after Save. |
| Picker selection assumed the Warm palette. | Warm uses bronze state colors; Standard uses graphite state colors. Both screens use `ChatPalette` semantic surfaces and neither restores a blue outline. |

Current local audit evidence was produced by `ModelPickerUITests` for Warm and
Standard picker/editor states plus the open image menu; that target is not part
of the upstream-shaped branch. Screenshot evidence cannot prove
VoiceOver reading order or keyboard behavior, so those remain covered by semantic
labels/identifiers and runtime interaction tests rather than visual claims.
