---
name: hermex-ios-form-factors
description: Use when changing Hermex's SwiftUI layout, supported device families, iPad behavior, or Mac Designed-for-iPhone/iPad support. Enforces iPhone regression plus iPad/Mac build and IPA metadata validation.
version: 1.0.0
author: Hermex maintainers
license: MIT
metadata:
  hermes:
    tags: [ios, swiftui, ipad, mac, testflight, validation]
    related_skills: []
---

# Hermex iOS Form-Factor Changes

## Overview

Hermex started as a phone-first SwiftUI app. Any change that expands or changes form-factor behavior must preserve the iPhone path while proving that iPad and Mac Designed-for-iPhone/iPad builds still compile and carry the correct App Store metadata.

This skill is deliberately narrow: it is not a general SwiftUI guide. It is the repo-local validation contract for device-family, wide-layout, navigation, and release-readiness changes.

## When to Use

Use this skill when a change touches any of these:

- `TARGETED_DEVICE_FAMILY`, `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD`, orientations, entitlements, or `Info.plist` device metadata.
- SwiftUI layout behavior for wide screens, split/navigation shells, readable content widths, sidebars, settings/tasks panels, or chat transcript/composer layout.
- iPad-specific behavior or Mac Designed-for-iPhone/iPad support.
- TestFlight release validation after a form-factor/layout change.

Do not use it for pure model/networking changes unless they also affect navigation or visible layout.

## Implementation Rules

1. **Preserve phone behavior first.** Treat the iPhone path as the regression baseline. Wide-screen improvements must be additive unless the issue explicitly asks for a phone UX change.
2. **Prefer adaptive primitives.** Use SwiftUI size classes, idiom checks, readable-width frames, split/navigation behavior, and shared design tokens rather than duplicating whole screens.
3. **Keep RTL and accessibility intact.** Do not hard-code left/right layout assumptions. Dynamic Type and reduced-motion/reduced-transparency behavior should continue to flow through existing helpers/tokens.
4. **Keep metadata and layout together.** If enabling iPad support, verify both project build settings and `Info.plist`; App Store metadata without working layout, or layout without target-family metadata, is incomplete.
5. **No incidental release edits.** Before archive/export/upload, the release tree must be clean except for the intended committed changes. Stash unrelated drafts rather than letting them ride into TestFlight.

## Validation Gate

Run these from the repo root unless the human explicitly scopes the work smaller.

### 1. Static metadata checks

```zsh
plutil -lint HermesMobile/Resources/Info.plist

git diff --check

xcodebuild -project HermesMobile.xcodeproj -scheme HermesMobile -showBuildSettings 2>/dev/null \
  | awk '/TARGETED_DEVICE_FAMILY|SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD/ {print}' \
  | sort -u
```

Completion: plist is valid, diff has no whitespace errors, and the build settings show the intended device-family/Mac support values.

### 2. Phone regression tests

```zsh
xcodebuild test \
  -project HermesMobile.xcodeproj \
  -scheme HermesMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Completion: full XCTest passes on the phone simulator. If `iPhone 17` is unavailable, use a nearby available iPhone simulator and report which one.

### 3. iPad build smoke

```zsh
xcodebuild build-for-testing \
  -project HermesMobile.xcodeproj \
  -scheme HermesMobile \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)'
```

Completion: iPad simulator build-for-testing succeeds. If that exact simulator is unavailable, choose a nearby available iPad and report it.

### 4. Mac Designed-for-iPhone/iPad compile

Find the local Mac destination with `xcrun xctrace list devices` or `xcrun simctl list devices`, then compile against that destination:

```zsh
xcodebuild build \
  -project HermesMobile.xcodeproj \
  -scheme HermesMobile \
  -destination 'id=<THIS_MAC_DEVICE_ID>' \
  CODE_SIGNING_ALLOWED=NO
```

Completion: Mac Designed-for-iPhone/iPad compile succeeds. This is compile-only; do not use `CODE_SIGNING_ALLOWED=NO` for simulator installs or manual login testing.

### 5. Release-only compile before archive

Before any TestFlight archive, run a Release/generic compile gate. This catches whole-module or Release-only failures that Debug simulator tests can miss.

```zsh
xcodebuild build \
  -project HermesMobile.xcodeproj \
  -scheme HermesMobile \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO
```

Completion: Release/generic compile succeeds from a clean tree.

### 6. IPA metadata check when uploading

After exporting an IPA, inspect the app `Info.plist` inside the IPA:

```zsh
python3 - <<'PY'
import json, plistlib, zipfile
from pathlib import Path
ipa = Path('<path-to-exported-ipa>')
with zipfile.ZipFile(ipa) as zf:
    for name in zf.namelist():
        if name.startswith('Payload/') and name.endswith('.app/Info.plist'):
            info = plistlib.load(zf.open(name))
            print(json.dumps({
                'bundle_id': info.get('CFBundleIdentifier'),
                'version': info.get('CFBundleShortVersionString'),
                'build': info.get('CFBundleVersion'),
                'device_family': info.get('UIDeviceFamily'),
                'ipad_orientations': info.get('UISupportedInterfaceOrientations~ipad'),
            }, indent=2))
PY
```

Completion: `UIDeviceFamily` includes both `1` and `2`, and expected iPad orientations are present.

## Manual Review Notes

For UI-affecting changes, give the human a short manual checklist covering:

- iPhone: existing navigation, session list, chat transcript, composer, settings/tasks still feel unchanged unless intentionally changed.
- iPad portrait and landscape: readable widths, navigation transitions, settings/tasks panels, and chat transcript/composer are not stretched awkwardly.
- Mac Designed-for-iPhone/iPad: main surfaces compile and launch; keyboard/resize behavior does not reveal obvious layout clipping.
- Accessibility: Dynamic Type, RTL, reduced motion/transparency where the touched surfaces rely on them.

## Common Pitfalls

1. **Only testing iPhone.** A phone-only test suite can pass while iPad metadata or Mac compile is broken.
2. **Using `CODE_SIGNING_ALLOWED=NO` for manual simulator installs.** That strips entitlements; Keychain login can fail with `errSecMissingEntitlement`. Use it only for compile-only checks.
3. **Archive from a dirty tree.** Release archives must correspond to a committed SHA. Stash unrelated drafts before archive/export/upload.
4. **Metadata without layout.** Adding `TARGETED_DEVICE_FAMILY = 1,2` is not enough; wide-screen surfaces need explicit review.
5. **Layout without metadata.** Adaptive SwiftUI code does not reach iPad/Mac users unless the target and plist metadata support it.

## Final Report

When done, report:

- files changed;
- device-family/Mac support values observed;
- exact iPhone, iPad, Mac, and Release/generic commands run;
- pass/fail result for each command;
- IPA metadata if a TestFlight build was exported/uploaded;
- remaining manual simulator/device checks for the human.
