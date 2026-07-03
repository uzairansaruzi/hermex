---
version: alpha
name: Zora Mobile
description: Warm Samantha-inspired mobile design system for the Zora iOS client. Coral/vermillion energy, ember depth, cream foregrounds, calm agentic surfaces.
colors:
  ink: "#2A0B03"
  primary: "#FA713D"
  secondary: "#E24A25"
  tertiary: "#B33C1E"
  neutral: "#FEF0DB"
  ember: "#7A2410"
  success: "#70D68E"
  warning: "#FFC26B"
  danger: "#FF7058"
  surface: "#9B321B"
  surface-strong: "#7A2410"
typography:
  brand:
    fontFamily: New York / system serif
    fontSize: 31px
    fontWeight: 400
    lineHeight: 1.1
    letterSpacing: "-0.62px"
  title:
    fontFamily: SF Pro
    fontSize: 31px
    fontWeight: 700
    lineHeight: 1.12
  body-md:
    fontFamily: SF Pro
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.45
  label:
    fontFamily: SF Pro
    fontSize: 13px
    fontWeight: 600
    lineHeight: 1.2
rounded:
  sm: 8px
  md: 22px
  lg: 28px
  pill: 999px
spacing:
  xs: 8px
  sm: 12px
  md: 16px
  lg: 24px
  xl: 32px
components:
  button-primary:
    backgroundColor: "{colors.neutral}"
    textColor: "{colors.ember}"
    rounded: "{rounded.sm}"
    padding: 15px
  button-secondary:
    backgroundColor: "{colors.tertiary}"
    textColor: "{colors.neutral}"
    rounded: "{rounded.sm}"
    padding: 15px
  surface-card:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.neutral}"
    rounded: "{rounded.md}"
    padding: 16px
  surface-sheet:
    backgroundColor: "{colors.surface-strong}"
    textColor: "{colors.neutral}"
    rounded: "{rounded.lg}"
    padding: 24px
  waveform-mark:
    backgroundColor: "{colors.surface-strong}"
    textColor: "{colors.neutral}"
    width: 54px
    height: 28px
  feedback-success:
    backgroundColor: "{colors.success}"
    textColor: "{colors.ink}"
    rounded: "{rounded.sm}"
    padding: 12px
  feedback-warning:
    backgroundColor: "{colors.warning}"
    textColor: "{colors.ink}"
    rounded: "{rounded.sm}"
    padding: 12px
  feedback-danger:
    backgroundColor: "{colors.danger}"
    textColor: "{colors.ink}"
    rounded: "{rounded.sm}"
    padding: 12px
---

## Overview

Zora Mobile uses a warm, Samantha-inspired brand system: coral and vermillion for energy, terracotta for depth, ember for grounding, and cream for almost all text and iconography. The UI should feel personal and alive without becoming toy-like: a calm agent cockpit, not a startup gradient aquarium.

The SwiftUI source of truth is `HermesMobile/Config/AppTheme.swift`:

- `ZoraBrand` owns semantic colors and brand constants.
- `ZoraSpacing`, `ZoraRadius`, and `ZoraMotion` own layout and movement tokens.
- `ZoraPrimaryButtonStyle`, `ZoraSecondaryButtonStyle`, `zoraSurface(...)`, `ZoraBrandBackground`, `ZoraHeaderWordmark`, and `ZoraWaveform` are the reusable primitives.
- New screens should use those primitives before introducing local color, spacing, radius, or motion values.

## Colors

- **Ink (`#2A0B03`)**: high-contrast text on bright feedback fills where ember is not quite dark enough.
- **Primary / Coral (`#FA713D`)**: the high-energy top of the brand background and the first accent option.
- **Secondary / Vermillion (`#E24A25`)**: the dominant mid-field brand color.
- **Tertiary / Terracotta (`#B33C1E`)**: warm depth for secondary controls and elevated surfaces.
- **Neutral / Paper (`#FEF0DB`)**: primary foreground, logo tint, high-emphasis button fill, and the default header/accent preset.
- **Ember (`#7A2410`)**: deepest background and dark text on cream fills.
- **Success / Warning / Danger**: semantic feedback colors, intentionally warm and saturated enough to remain visible on ember surfaces.

Avoid cold greys, blues, purples, and generic AI sparkle colors on branded surfaces. If a non-brand color is needed for a status state, add it to `ZoraBrand` first and document why.

## Typography

The brand wordmark uses a system serif, italic, regular-weight treatment to move away from generic rounded-SF branding. Product copy stays on SF Pro/system fonts for legibility.

Use:

- large bold system type for page titles and onboarding headlines;
- `AppFont` helpers where the app already uses them;
- `ZoraBrand.foreground`, `secondaryForeground`, and `tertiaryForeground` for text hierarchy;
- no raw `.white` foregrounds on branded screens.

## Layout

Spacing is based on an 8pt grid:

- `ZoraSpacing.unit = 8`
- `ZoraSpacing.card = 16`
- `ZoraSpacing.section = 24`
- `ZoraSpacing.screenInset = 24`

Primary page content may use `screenInset + unit / 2` for onboarding-style breathing room, but the expression should stay token-derived. Avoid unexplained `22`, `24`, `28`, etc. in new layout code unless the value is a local drawing measurement rather than layout spacing.

## Elevation & Depth

Depth comes from warm translucent surfaces over `ZoraBrandBackground`, not neutral system cards. Use:

- `zoraSurface(.subtle)` for chips, badges, inline fields, and quiet callouts;
- `zoraSurface(.card)` for grouped content;
- `zoraSurface(.strong)` for emphasized panels;
- `zoraSurface(.chrome)` for persistent bars and UI chrome.

Reduced-transparency users receive more opaque warm fills through `ZoraSurfaceLevel.fill(reduceTransparency:)`.

## Shapes

- Controls: `ZoraRadius.small` / `8px` for compact buttons and text fields.
- Cards: `ZoraRadius.card` / `22px`.
- Sheets: `ZoraRadius.sheet` / `28px`.
- Pills: `ZoraRadius.control` / `999px`.

Prefer continuous rounded rectangles in SwiftUI. Do not mix arbitrary radii across equivalent surfaces.

## Components

### Brand background

Use `ZoraBrandBackground()` or `.zoraBrandedScreen()` for app-level branded screens. It layers coral, vermillion, terracotta, ember, and a cream highlight.

### Wordmark and waveform

Use `ZoraHeaderWordmark()` for the header mark. The mark combines:

- `ZoraWaveform`, a timeline-driven waveform shape;
- `ZoraWaveState.idle`, `.listening`, `.speaking(intensity:)`, and `.thinking` states;
- a serif italic `Zora` wordmark.

Respect reduced motion. `ZoraWaveform` automatically renders an idle state when `accessibilityReduceMotion` is enabled.

### Buttons

Use `ZoraPrimaryButtonStyle` and `ZoraSecondaryButtonStyle`. The primary button is cream-on-ember; secondary buttons use translucent warm surfaces and cream foregrounds. Onboarding-specific button styles should not be reintroduced.

### Surfaces

Use `zoraSurface(...)` before local `background(...).overlay(...)` stacks. Local surface code is acceptable only for drawing primitives or state-specific feedback where the tint is intentionally dynamic.

### App icons

The asset catalog contains Zora/Samantha icon variants for light, ember, pulse, monochrome, and gradient modes. Settings labels should use Zora names rather than generic Light/Dark/Disco naming.

## Do's and Don'ts

Do:

- Route new visual decisions through `AppTheme.swift` tokens first.
- Keep branded screens warm and dark-context by default.
- Use `ZoraBrand.foreground` instead of `.white` on branded UI.
- Use token-derived spacing and radii on primary surfaces.
- Validate with build/tests and at least one simulator screenshot pass after visual changes.

Don't:

- Scatter raw hex values or raw `.white` foregrounds through SwiftUI views.
- Add one-off button styles when `ZoraPrimaryButtonStyle` / `ZoraSecondaryButtonStyle` will do.
- Reintroduce cold blue/purple/cyan accent colors on onboarding or brand surfaces.
- Use animation as the only state signal; pair it with text, accessibility labels, or icons.
- Make a single screen look branded while adjacent primary screens keep system-neutral styling.
