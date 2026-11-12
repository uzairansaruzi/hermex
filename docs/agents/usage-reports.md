# Usage reports

Usage reports are optional and off until the user allows them. When allowed, the
main app sends one small report a week to the developer. This page is the map;
#1659 holds the decisions behind it.

## What is never sent

Message text, server URLs or host names, server names, credentials, headers,
file names, error text, and a server's custom version string. No account and no
device identifier field. The report type (`UsageReport`) has no field that could
hold any of these, and `UsageReportsTests` checks the encoded bytes.

## The contract

`UsageReport` in `HermesMobile/Config/UsageReports.swift` is the wire format: one
JSON object, every key required. The collector rejects an unknown key, a missing
key, or a value outside its limits, so the two change together. Fields:

- `v`, the format version the user accepted. `week` (ISO week in UTC),
  `channel` (`appstore` or `testflight`, from the StoreKit app transaction),
  `app_version`, `os_version`, `device_model` (hardware identifier),
  `language` (the app's display language), `region` (the device's region),
  `install_day` (the first-launch date `RatingPromptSettings.firstLaunchDateKey`
  as a UTC day).
- `days_active` (UTC days with a foreground), `first_report_of_month`,
  `completed_responses` (a weekly count beside the all-time one).
- `servers`: counts by kind and each server's kind and release. A version is a
  plain release number, `other`, or `unknown`; a webui server stores none, so it
  is always `unknown`. Building a report makes no server request.
- `features`: yes or no for the week, from `UsageFeature`. Each is tallied where
  the user does it: the destination screen's appearance (Workspace's file browser
  and manager, Tasks, Skills, Memory, Insights, Kanban, a Bot chat or room), the
  composer's audio capture (`ComposerAudioCaptureState`), a consumed share with
  no Shortcut destination, a Bot or Limits widget link, a started Live Activity,
  and a drained App Intent link (`ContentView`). Extensions get no code.
- `settings`: push (any configured server has a pairing) and App Lock, read
  when the report is built.
- `cards`: the tip and star cards' `shown`, `dismissed` (their X) and
  `link_opened` (their own button). Settings › About's rows don't count.

The collector adds the arrival day and Cloudflare's country code; it never
stores the IP address.

## Privacy manifest and App Store label

`HermesMobile/Resources/PrivacyInfo.xcprivacy` declares four collected data
types for the report, each not linked, not tracking, purpose Analytics. The App
Store privacy label carries the same four, and both change in the release that
ships the report. The push Device ID entry is separate and unchanged; the share
extension's manifest is unchanged, since it sends nothing.

| Data type | Fields |
| --- | --- |
| Product Interaction | `features`, `days_active`, `completed_responses`, `cards` |
| Other Usage Data | `servers`, `settings` |
| Coarse Location | the country the collector derives from the connection |
| Other Data Types | `device_model`, `os_version`, `app_version`, `language`, `region`, `install_day` |

Adding a field to the report means checking it against this table, and adding a
data type here and on the label when none fits.

## Consent

- One device-wide answer (`UsageReports.Keys`), not per server. Nothing is
  tallied or sent unless reports are allowed and a server is configured.
- The session list card (`SessionListCard.usageReports`) asks from 5 completed
  responses, ahead of the tip and star cards and under their guards. It has no
  X: Allow and No thanks are its only ways out, and "See what's sent" opens the
  preview without answering.
- Settings › About › Usage Reports has the same switch and preview. Turning it
  off erases the tallies; reports already sent can't be recalled.
- Before consent the preview is a labelled example with sample weekly values;
  after, it is this week so far, from the builder the sender uses.

## Format versions

The app stores the version the user accepted and encodes that one. A build with
a newer version that adds fields bumps `UsageReport.currentVersion`, lists the
fields in `fieldsAdded(after:)`, and the card asks again; No thanks keeps the old
version and doesn't ask again for that one. Only version 1 exists.

## Sending

On each foreground, before recording that day, `UsageReports.appBecameActive`
sends last week's tallies if no send was attempted for that week, and discards
anything older. The attempt is recorded before the post, consent is checked again
just before it, and a failure is never retried. Debug builds never send. The
request goes to the fixed collector URL through an ephemeral session with no
cookies, credentials or custom headers.

## Collector

`uzairansaruzi/hermex-stats`: one Cloudflare Worker and one D1 database, separate
from `hermex-push` so a report can never be joined to a device token. Its README
owns deployment, validation, and the private dashboard.
