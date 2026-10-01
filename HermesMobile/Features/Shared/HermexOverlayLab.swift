#if DEBUG
import SwiftUI

/// DEBUG-only lab (`--hermex-overlay-lab`) exercising unadopted custom same-window overlay
/// components — `HermexDialog` and `HermexPopoverMenu` — plus a small set of rendered-verification
/// fixtures for shared components that changed in Batch A (`SegmentedControl`, `HermexToast`,
/// `HermexBottomSheet`) — in a signed simulator build, so their rendered behavior (motion,
/// accessibility, Reduce Motion/Transparency, exactly-once dismissal) can be verified without any
/// production call site. Not reachable in Release builds and not a production adoption surface (see
/// `HermesMobileApp`); the Batch A and Batch B follow-up sections exist to visually confirm those
/// source-contract changes render correctly, not to adopt the components anywhere.
/// `--hermex-overlay-lab-popover` scrolls straight to the Popover section on launch,
/// `--hermex-overlay-lab-followup` scrolls straight to the Batch A follow-up section, and
/// `--hermex-overlay-lab-batch-b` scrolls straight to the Batch B follow-up section — deterministic
/// seams so a fresh relaunch always brings those fixtures into view without manual scrolling.
/// `--hermex-overlay-lab-batch-b-controls` targets the lower selection-controls subsection when host
/// scrolling is unavailable. `--hermex-overlay-lab-round-3-list-item` targets the Round 3 ListItem
/// fixture directly. `--hermex-overlay-lab-search` scrolls straight to the Search section,
/// exercising the custom `HermexSearchField`/`.hermexSearch` foundation the same way.
/// `--hermex-overlay-lab-selection-sheet` scrolls straight to the Selection Sheet section (Issue
/// #607, DSF-06), exercising the caller-presented `HermexSelectionSheet` foundation that replaced
/// the retired `HermexDropdown`. `--hermex-overlay-lab-banner` scrolls straight to the Banner
/// section (Issue #607, DSR2-15), exercising the `HermexBanner` foundation's title+description,
/// title-only, and description-only content combinations, plus a specimen mirroring the main chat
/// composer's description-only inset error placement — the lab's own fixture, not the production
/// call site. `--hermex-overlay-lab-text-input` scrolls straight to the Text Input section (Issue
/// #607, DSR2-06), exercising real `HermexTextField`, `HermexSecureField`, and `HermexCodeInput`
/// specimens at 4/6/8-digit lengths and partial/complete/error/disabled states.
/// `--hermex-overlay-lab-composer-toolbar` scrolls straight to the Composer Toolbar section (Issue
/// #607, DSR2-09), exercising the unadopted `HermexComposerToolbar` foundation's elevated and
/// transparent appearances at fitting and overflowing content widths — the lab's own fixture, not a
/// production call site.
struct HermexOverlayLab: View {
    @State private var forceReduceMotion = ProcessInfo.processInfo.arguments.contains("--hermex-overlay-lab-reduce-motion")
    @State private var forceReduceTransparency = ProcessInfo.processInfo.arguments.contains("--hermex-overlay-lab-reduce-transparency")
    private let jumpsToPopoverSection = ProcessInfo.processInfo.arguments.contains("--hermex-overlay-lab-popover")
    private let jumpsToFollowupSection = ProcessInfo.processInfo.arguments.contains("--hermex-overlay-lab-followup")
    private let jumpsToBatchBSection = ProcessInfo.processInfo.arguments.contains("--hermex-overlay-lab-batch-b")
    private let jumpsToBatchBSelectionControls = ProcessInfo.processInfo.arguments.contains("--hermex-overlay-lab-batch-b-controls")
    private let jumpsToRound3ListItemSection = ProcessInfo.processInfo.arguments.contains("--hermex-overlay-lab-round-3-list-item")
    private let jumpsToSearchSection = ProcessInfo.processInfo.arguments.contains("--hermex-overlay-lab-search")
    private let jumpsToSelectionSheetSection = ProcessInfo.processInfo.arguments.contains("--hermex-overlay-lab-selection-sheet")
    private let jumpsToBannerSection = ProcessInfo.processInfo.arguments.contains("--hermex-overlay-lab-banner")
    private let jumpsToTextInputSection = ProcessInfo.processInfo.arguments.contains("--hermex-overlay-lab-text-input")
    private let jumpsToComposerToolbarSection = ProcessInfo.processInfo.arguments.contains("--hermex-overlay-lab-composer-toolbar")

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    controls
                    Divider()
                    dialogSection
                    Divider()
                    followupSection
                        .id(HermexOverlayLabFollowupSection.scrollAnchorID)
                    Divider()
                    popoverSection
                        .id(HermexOverlayLabPopoverSection.scrollAnchorID)
                    Divider()
                    batchBSection
                        .id(HermexOverlayLabBatchBSection.scrollAnchorID)
                    Divider()
                    searchSection
                        .id(HermexOverlayLabSearchSection.scrollAnchorID)
                    Divider()
                    selectionSheetSection
                        .id(HermexOverlayLabSelectionSheetSection.scrollAnchorID)
                    Divider()
                    bannerSection
                        .id(HermexOverlayLabBannerSection.scrollAnchorID)
                    Divider()
                    textInputSection
                        .id(HermexOverlayLabTextInputSection.scrollAnchorID)
                    Divider()
                    composerToolbarSection
                        .id(HermexOverlayLabComposerToolbarSection.scrollAnchorID)
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(Text(verbatim: "Overlay Lab"))
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if jumpsToPopoverSection {
                    proxy.scrollTo(HermexOverlayLabPopoverSection.scrollAnchorID, anchor: .top)
                } else if jumpsToFollowupSection {
                    proxy.scrollTo(HermexOverlayLabFollowupSection.scrollAnchorID, anchor: .top)
                } else if jumpsToBatchBSection {
                    proxy.scrollTo(HermexOverlayLabBatchBSection.scrollAnchorID, anchor: .top)
                } else if jumpsToBatchBSelectionControls {
                    proxy.scrollTo(HermexOverlayLabBatchBSelectionControls.scrollAnchorID, anchor: .top)
                } else if jumpsToRound3ListItemSection {
                    proxy.scrollTo(HermexOverlayLabRound3ListItemSection.scrollAnchorID, anchor: .top)
                } else if jumpsToSearchSection {
                    proxy.scrollTo(HermexOverlayLabSearchSection.scrollAnchorID, anchor: .top)
                } else if jumpsToSelectionSheetSection {
                    proxy.scrollTo(HermexOverlayLabSelectionSheetSection.scrollAnchorID, anchor: .top)
                } else if jumpsToBannerSection {
                    proxy.scrollTo(HermexOverlayLabBannerSection.scrollAnchorID, anchor: .top)
                } else if jumpsToTextInputSection {
                    proxy.scrollTo(HermexOverlayLabTextInputSection.scrollAnchorID, anchor: .top)
                } else if jumpsToComposerToolbarSection {
                    proxy.scrollTo(HermexOverlayLabComposerToolbarSection.scrollAnchorID, anchor: .top)
                }
            }
        }
        // SwiftUI exposes no public writable override for these two accessibility settings; the
        // same underscored keys are already used from `HermesMobileTests` on a live hosted window,
        // not only from `#Preview`, so they are safe to force here for a rendered manual pass.
        .environment(\._accessibilityReduceMotion, forceReduceMotion)
        .environment(\._accessibilityReduceTransparency, forceReduceTransparency)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "Overlay Lab").font(.title3.weight(.semibold))
            Toggle(isOn: $forceReduceMotion) { Text(verbatim: "Force Reduce Motion") }
                .accessibilityIdentifier("overlay-lab-force-reduce-motion")
            Toggle(isOn: $forceReduceTransparency) { Text(verbatim: "Force Reduce Transparency") }
                .accessibilityIdentifier("overlay-lab-force-reduce-transparency")
        }
        .font(.subheadline)
    }

    private var dialogSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: "Dialog").font(.headline)
            HermexOverlayLabHorizontalConfirmation()
            HermexOverlayLabVerticalExplanation()
            HermexOverlayLabLongBody()
            HermexOverlayLabAccessibilitySize()
            HermexOverlayLabRepeatedPresentDismiss()
            HermexOverlayLabDismissThenRun()
            HermexOverlayLabBackdropBlocksInput()
            HermexOverlayLabAccessibilityOrder()
        }
    }

    private var followupSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: "Batch A Follow-up").font(.headline)
            HermexOverlayLabSegmentedControlFollowup()
            HermexOverlayLabToastFollowup()
            HermexOverlayLabBottomSheetFollowup()
        }
    }

    private var popoverSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: "Popover Menu").font(.headline)
            HermexOverlayLabPopoverBelowFit()
            HermexOverlayLabPopoverAboveFlip()
            HStack(spacing: 12) {
                HermexOverlayLabPopoverLeadingClamp()
                Spacer()
                HermexOverlayLabPopoverTrailingClamp()
            }
            HermexOverlayLabPopoverLongScroll()
            HermexOverlayLabPopoverDisabledFirstRow()
            HermexOverlayLabPopoverDestructiveRow()
            HermexOverlayLabPopoverOutsideTapDismiss()
            HermexOverlayLabPopoverDismissThenRun()
            HermexOverlayLabPopoverAccessibilitySize()
        }
    }

    private var batchBSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: "Batch B Follow-up").font(.headline)
            HermexOverlayLabCardFollowup()
            HermexOverlayLabAccordionFollowup()
            HermexOverlayLabAccordionNoLeadingFollowup()
            HermexOverlayLabListItemFollowup()
                .id(HermexOverlayLabRound3ListItemSection.scrollAnchorID)
            HermexOverlayLabSelectionControlsFollowup()
                .id(HermexOverlayLabBatchBSelectionControls.scrollAnchorID)
        }
    }

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: "Search").font(.headline)
            HermexOverlayLabSearchFollowup()
        }
    }

    private var selectionSheetSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: "Selection Sheet").font(.headline)
            HermexOverlayLabSelectionSheetSingle()
            HermexOverlayLabSelectionSheetMultiHorizontal()
            HermexOverlayLabSelectionSheetMultiVertical()
            HermexOverlayLabSelectionSheetSearch()
            HermexOverlayLabSelectionSheetLongList()
            HermexOverlayLabSelectionSheetNoInset()
        }
    }

    // Specimens are inlined directly (not separate fixture structs, unlike the sections above) so
    // this whole section — anchor, all three content-combination specimens, and the composer-error
    // specimen with its dismiss action — stays in one place, matching the approved composer copy.
    private var bannerSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: "Banner").font(.headline)
                .accessibilityIdentifier("overlay-lab-banner-section")

            Text(verbatim: "Title + description, with an action").font(.subheadline.weight(.semibold))
            HermexBanner(
                .warning,
                title: Text(verbatim: "Update available"),
                description: Text(verbatim: "A new version fixes a known issue."),
                action: HermexBanner.Action(title: "Update") {}
            )
            .accessibilityIdentifier("overlay-lab-banner-title-description")

            Text(verbatim: "Title only").font(.subheadline.weight(.semibold))
            HermexBanner(.success, title: Text(verbatim: "Synced"))
                .accessibilityIdentifier("overlay-lab-banner-title-only")

            Text(verbatim: "Description only").font(.subheadline.weight(.semibold))
            HermexBanner(.information, description: Text(verbatim: "All caught up."))
                .accessibilityIdentifier("overlay-lab-banner-description-only")

            Text(verbatim: "Composer error (description-only, inset, icon hidden)").font(.subheadline.weight(.semibold))
            HermexBanner(.error,
                title: nil,
                description: Text(verbatim: "The Hermes server hit an internal error. Check the server logs, then try again."),
                showsIcon: false, presentation: .inset,
                action: HermexBanner.Action(icon: "xmark", accessibilityLabel: "Dismiss attachment error") {}
            ).accessibilityIdentifier("overlay-lab-banner-composer-error")
        }
    }

    private var textInputSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: "Text Input").font(.headline)
                .accessibilityIdentifier("overlay-lab-text-input-section")
            HermexOverlayLabTextInputFollowup()
        }
    }

    // Specimens are inlined directly (not a separate fixture struct, unlike the sections above) so
    // this whole section — anchor and all three appearance/overflow specimens — stays in one place,
    // keeping the "no Send/Stop control" contract scoped to exactly this block.
    private var composerToolbarSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: "Composer Toolbar").font(.headline)
                .accessibilityIdentifier("overlay-lab-composer-toolbar-section")

            Text(verbatim: "Elevated, fitting content").font(.subheadline.weight(.semibold))
            HermexComposerToolbar(appearance: .elevated) {
                Button("Model") {}
                    .buttonStyle(.hermex(.small, emphasis: .secondary))
                Button("Profile") {}
                    .buttonStyle(.hermex(.small, emphasis: .secondary))
                HermexComposerToolbarDivider()
                Button("Attach") {}
                    .buttonStyle(.hermex(.small, emphasis: .secondary))
            }
            .accessibilityIdentifier("overlay-lab-composer-toolbar-elevated-fitting")

            Text(verbatim: "Elevated, overflowing content").font(.subheadline.weight(.semibold))
            HermexComposerToolbar(appearance: .elevated) {
                ForEach(1...10, id: \.self) { index in
                    Button("Option \(index)") {}
                        .buttonStyle(.hermex(.small, emphasis: .secondary))
                }
            }
            .accessibilityIdentifier("overlay-lab-composer-toolbar-elevated-overflow")

            Text(verbatim: "Transparent, inside Card").font(.subheadline.weight(.semibold))
            HermexComposerToolbar(appearance: .transparent) {
                Button("Model") {}
                    .buttonStyle(.hermex(.small, emphasis: .secondary))
                Button("Profile") {}
                    .buttonStyle(.hermex(.small, emphasis: .secondary))
                HermexComposerToolbarDivider()
                Button("Attach") {}
                    .buttonStyle(.hermex(.small, emphasis: .secondary))
            }
            .padding(HermexCardMetrics.contentPadding)
            .hermexCardSurface(.outlined)
            .accessibilityIdentifier("overlay-lab-composer-toolbar-transparent")

            // One ordered, zero-or-more arbitrary-content slot, not a button-only concept: mixes a
            // display-only Tag with a real control in the same row to demonstrate that.
            Text(verbatim: "Elevated, mixed content").font(.subheadline.weight(.semibold))
            HermexComposerToolbar(appearance: .elevated) {
                Tag(label: "Draft", tint: .orange, size: .compact)
                Button("Model") {}
                    .buttonStyle(.hermex(.small, emphasis: .secondary))
            }
            .accessibilityIdentifier("overlay-lab-composer-toolbar-mixed-content")
        }
    }
}

/// Namespaces the scroll-anchor identifier `--hermex-overlay-lab-banner` jumps to on launch.
private enum HermexOverlayLabBannerSection {
    static let scrollAnchorID = "overlay-lab-banner-scroll"
}

/// Namespaces the scroll-anchor identifier `--hermex-overlay-lab-popover` jumps to on launch.
private enum HermexOverlayLabPopoverSection {
    static let scrollAnchorID = "overlay-lab-popover-section"
}

/// Namespaces the scroll-anchor identifier `--hermex-overlay-lab-followup` jumps to on launch.
private enum HermexOverlayLabFollowupSection {
    static let scrollAnchorID = "overlay-lab-followup-section"
}

/// Namespaces the scroll-anchor identifier `--hermex-overlay-lab-batch-b` jumps to on launch.
private enum HermexOverlayLabBatchBSection {
    static let scrollAnchorID = "overlay-lab-batch-b-section"
}

/// Namespaces the lower Batch B selection-controls scroll target used when host input is unavailable.
private enum HermexOverlayLabBatchBSelectionControls {
    static let scrollAnchorID = "overlay-lab-batch-b-selection-controls"
}

/// Namespaces the Round 3 ListItem target used when host scrolling is unavailable.
private enum HermexOverlayLabRound3ListItemSection {
    static let scrollAnchorID = "overlay-lab-round-3-list-item-scroll"
}

/// Namespaces the scroll-anchor identifier `--hermex-overlay-lab-search` jumps to on launch.
private enum HermexOverlayLabSearchSection {
    static let scrollAnchorID = "overlay-lab-search-section"
}

/// Namespaces the scroll-anchor identifier `--hermex-overlay-lab-selection-sheet` jumps to on launch.
private enum HermexOverlayLabSelectionSheetSection {
    static let scrollAnchorID = "overlay-lab-selection-sheet-section"
}

/// Namespaces the scroll-anchor identifier `--hermex-overlay-lab-text-input` jumps to on launch.
private enum HermexOverlayLabTextInputSection {
    static let scrollAnchorID = "overlay-lab-text-input-scroll"
}

/// Namespaces the scroll-anchor identifier `--hermex-overlay-lab-composer-toolbar` jumps to on launch.
private enum HermexOverlayLabComposerToolbarSection {
    static let scrollAnchorID = "overlay-lab-composer-toolbar-scroll"
}

// ─── 1. Short confirmation, horizontal footer ──────────────────────────────────
private struct HermexOverlayLabHorizontalConfirmation: View {
    // The extra DEBUG-only argument makes one deterministic rendered screenshot possible in
    // headless simulator sessions where no pointer-driving tool is available. The ordinary lab
    // route remains interactive and starts closed.
    @State private var isPresented = ProcessInfo.processInfo.arguments.contains("--hermex-overlay-lab-auto-dialog")

    var body: some View {
        Button("Short confirmation (horizontal)") { isPresented = true }
            .accessibilityIdentifier("overlay-lab-dialog-horizontal-trigger")
            .hermexDialog(isPresented: $isPresented, footerAxis: .horizontal) {
                Text(verbatim: "Delete this draft?").font(.headline)
            } content: {
                Text(verbatim: "This removes the unsent draft from this device. It cannot be undone.")
                    .font(.body)
            } footer: { context in
                Button("Cancel") { context.dismiss() }
                    .buttonStyle(.hermex(.medium, emphasis: .secondary))
                Button("Delete") { context.dismissAfter {} }
                    .buttonStyle(.hermex(.medium, emphasis: .destructive))
            }
    }
}

// ─── 2. Explanatory dialog, vertical footer ────────────────────────────────────
private struct HermexOverlayLabVerticalExplanation: View {
    @State private var isPresented = false

    var body: some View {
        Button("Explanatory dialog (vertical)") { isPresented = true }
            .accessibilityIdentifier("overlay-lab-dialog-vertical-trigger")
            .hermexDialog(isPresented: $isPresented, footerAxis: .vertical) {
                Text(verbatim: "Turn on notifications?").font(.headline)
            } content: {
                Text(verbatim: "Hermex can notify you when a session needs your attention, even while the app is closed.")
                    .font(.body)
            } footer: { context in
                Button("Turn On") { context.dismissAfter {} }
                    .buttonStyle(.hermex(.medium, emphasis: .primary))
                Button("Not Now") { context.dismiss() }
                    .buttonStyle(.hermex(.medium, emphasis: .neutral))
            }
    }
}

// ─── 3. Long-but-contract-valid body at small phone height ────────────────────
private struct HermexOverlayLabLongBody: View {
    @State private var isPresented = ProcessInfo.processInfo.arguments.contains("--hermex-overlay-lab-auto-long-dialog")

    var body: some View {
        Button("Long-but-valid body") { isPresented = true }
            .accessibilityIdentifier("overlay-lab-dialog-long-body-trigger")
            .hermexDialog(isPresented: $isPresented) {
                Text(verbatim: "Server certificate changed").font(.headline)
            } content: {
                Text(verbatim: "The certificate this server presents no longer matches the one Hermex trusted before. This can happen after a routine renewal, or it can mean the connection is no longer private. Only continue if you recognize this change.")
                    .font(.body)
            } footer: { context in
                Button("Cancel") { context.dismiss() }
                    .buttonStyle(.hermex(.medium, emphasis: .secondary))
                Button("Continue") { context.dismissAfter {} }
                    .buttonStyle(.hermex(.medium, emphasis: .primary))
            }
    }
}

// ─── 4. Largest supported accessibility Dynamic Type size ─────────────────────
private struct HermexOverlayLabAccessibilitySize: View {
    @State private var isPresented = ProcessInfo.processInfo.arguments.contains("--hermex-overlay-lab-auto-accessibility-dialog")

    var body: some View {
        Button("Largest accessibility text size") { isPresented = true }
            .accessibilityIdentifier("overlay-lab-dialog-accessibility-size-trigger")
            .hermexDialog(isPresented: $isPresented, footerAxis: .vertical) {
                Text(verbatim: "Stop this session?").font(.headline)
            } content: {
                Text(verbatim: "The agent stops after finishing its current step.")
                    .font(.body)
            } footer: { context in
                Button("Keep Going") { context.dismiss() }
                    .buttonStyle(.hermex(.medium, emphasis: .secondary))
                Button("Stop") { context.dismissAfter {} }
                    .buttonStyle(.hermex(.medium, emphasis: .destructive))
            }
            .dynamicTypeSize(.accessibility5)
    }
}

// ─── 5/6. Reduce Motion and Reduce Transparency are forced globally by the
// lab's own toggles above (`controls`), so every specimen exercises both. ──────

// ─── 7. Repeated present/dismiss ───────────────────────────────────────────────
private struct HermexOverlayLabRepeatedPresentDismiss: View {
    @State private var isPresented = false
    @State private var closeCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Repeated present/dismiss") { isPresented = true }
                .accessibilityIdentifier("overlay-lab-dialog-repeated-trigger")
            Text(verbatim: "Closed \(closeCount) times")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("overlay-lab-repeated-close-count")
        }
        .hermexDialog(isPresented: $isPresented) {
            Text(verbatim: "Repeat me").font(.headline)
        } content: {
            Text(verbatim: "Close this and reopen it a few times to confirm nothing leaks or double-fires.")
                .font(.body)
        } footer: { context in
            Button("Close") { context.dismissAfter { closeCount += 1 } }
                .buttonStyle(.hermex(.medium, emphasis: .primary))
        }
    }
}

// ─── 8. Dismiss-then-run counter: the action only changes after exit ──────────
private struct HermexOverlayLabDismissThenRun: View {
    @State private var isPresented = false
    @State private var actionCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Dismiss-then-run counter") { isPresented = true }
                .accessibilityIdentifier("overlay-lab-dialog-dismiss-then-run-trigger")
            Text(verbatim: "Action ran \(actionCount) times")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("overlay-lab-dismiss-then-run-count")
        }
        .hermexDialog(isPresented: $isPresented) {
            Text(verbatim: "Archive session?").font(.headline)
        } content: {
            Text(verbatim: "The counter below only advances after this dialog has fully closed.")
                .font(.body)
        } footer: { context in
            Button("Cancel") { context.dismiss() }
                .buttonStyle(.hermex(.medium, emphasis: .secondary))
            Button("Archive") { context.dismissAfter { actionCount += 1 } }
                .buttonStyle(.hermex(.medium, emphasis: .primary))
        }
    }
}

// ─── 9. Background counter proving backdrop taps never pass through ───────────
private struct HermexOverlayLabBackdropBlocksInput: View {
    @State private var isPresented = false
    @State private var backgroundTapCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Backdrop-blocks-input") { isPresented = true }
                .accessibilityIdentifier("overlay-lab-dialog-backdrop-trigger")
            Button("Background counter: \(backgroundTapCount)") { backgroundTapCount += 1 }
                .accessibilityIdentifier("overlay-lab-background-tap-counter")
        }
        .hermexDialog(isPresented: $isPresented) {
            Text(verbatim: "Backdrop is inert").font(.headline)
        } content: {
            Text(verbatim: "Tapping the dimmed area behind this dialog must never change the counter behind it.")
                .font(.body)
        } footer: { context in
            Button("Close") { context.dismiss() }
                .buttonStyle(.hermex(.medium, emphasis: .primary))
        }
    }
}

// ─── 10. Heading/body/footer/close accessibility order + trigger focus restore ─
private struct HermexOverlayLabAccessibilityOrder: View {
    @State private var isPresented = false

    var body: some View {
        Button("Accessibility order + focus return") { isPresented = true }
            .accessibilityIdentifier("overlay-lab-a11y-order-trigger")
            .hermexDialog(isPresented: $isPresented) {
                Text(verbatim: "Heading reads first")
                    .font(.headline)
                    .accessibilityIdentifier("overlay-lab-a11y-heading")
            } content: {
                Text(verbatim: "Body reads second.")
                    .font(.body)
                    .accessibilityIdentifier("overlay-lab-a11y-body")
            } footer: { context in
                Button("Footer reads third") { context.dismiss() }
                    .buttonStyle(.hermex(.medium, emphasis: .secondary))
                    .accessibilityIdentifier("overlay-lab-a11y-footer")
            }
    }
}

// ─── Batch A follow-up fixtures ─────────────────────────────────────────────────
// Rendered-verification specimens for shared components whose source contract changed in Batch A
// (DSF-01..DSF-04). These exist to confirm the changes render correctly on device/simulator, not to
// adopt the components at any production call site.

// ─── Segmented Control: fixed vs. scrolling geometry side by side ─────────────
private struct HermexOverlayLabSegmentedControlFollowup: View {
    private enum Filter: String, CaseIterable, Hashable {
        case all, active, done
    }

    @State private var fixedSelection: Filter = .active
    @State private var scrollingSelection: Filter = .active

    private var options: [SegmentedControlOption<Filter>] {
        [
            SegmentedControlOption(value: .all, title: "All"),
            SegmentedControlOption(value: .active, title: "Active"),
            SegmentedControlOption(value: .done, title: "Done")
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "Segmented Control (fixed vs. scrolling)").font(.subheadline.weight(.semibold))
            SegmentedControl("Filter (fixed)", selection: $fixedSelection, options: options, style: .fixed)
                .accessibilityIdentifier("overlay-lab-followup-segmented-fixed")
            SegmentedControl("Filter (scrolling)", selection: $scrollingSelection, options: options, style: .scrolling)
        }
    }
}

// ─── Toast: success specimen with and without a trailing action ───────────────
private struct HermexOverlayLabToastFollowup: View {
    @State private var undoCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "Toast (success, with and without action)").font(.subheadline.weight(.semibold))
            HermexToast(.success, message: Text(verbatim: "Draft saved"))
            HermexToast(
                .success,
                message: Text(verbatim: "Message sent"),
                action: .init(title: "Undo") { undoCount += 1 }
            )
            .accessibilityIdentifier("overlay-lab-followup-toast")
            Text(verbatim: "Undo ran \(undoCount) times")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("overlay-lab-followup-toast-undo-count")

            Text(verbatim: "All four semantic surfaces").font(.subheadline.weight(.semibold))
            HermexToast(.information, message: Text(verbatim: "A new version is available"))
                .accessibilityIdentifier("overlay-lab-toast-information")
            HermexToast(.success, message: Text(verbatim: "Draft saved"))
                .accessibilityIdentifier("overlay-lab-toast-success")
            HermexToast(.warning, message: Text(verbatim: "Connection is unstable"))
                .accessibilityIdentifier("overlay-lab-toast-warning")
            HermexToast(.error, message: Text(verbatim: "Failed to send message"))
                .accessibilityIdentifier("overlay-lab-toast-error")
        }
    }
}

// ─── Bottom Sheet: icon-first TopNav slots on the scoped glass default, borderless footer ─
private struct HermexOverlayLabBottomSheetFollowup: View {
    @State private var isPresented = ProcessInfo.processInfo.arguments.contains("--hermex-overlay-lab-auto-bottom-sheet")

    var body: some View {
        Button("Bottom sheet (icon-first TopNav)") { isPresented = true }
            .accessibilityIdentifier("overlay-lab-followup-bottom-sheet-trigger")
            .sheet(isPresented: $isPresented) {
                HermexBottomSheet("Rename Session") {
                    Text(verbatim: "Choose a name that helps you find this session later.")
                        .font(.body)
                        .padding(.horizontal, HermesSpacing.screenHorizontal)
                        .padding(.top, HermesSpacing.s12)
                } leadingPrimary: {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(Text("Cancel"))
                } trailingPrimary: {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel(Text("Save"))
                } footer: {
                    Button("Cancel") { isPresented = false }
                        .buttonStyle(.hermex(.medium, emphasis: .secondary))
                    Button("Save") { isPresented = false }
                        .buttonStyle(.hermex(.medium, emphasis: .primary))
                }
            }
    }
}

// ─── Popover Menu fixtures ──────────────────────────────────────────────────────

// ─── 1/2. Anchor near the top: prefers below; near the bottom: flips above ─────
private struct HermexOverlayLabPopoverBelowFit: View {
    @State private var isPresented = false

    var body: some View {
        Button("Below fit (top anchor)") { isPresented = true }
            .accessibilityIdentifier("overlay-lab-popover-below-trigger")
            .hermexPopoverMenu(
                isPresented: $isPresented,
                accessibilityLabel: Text("Row actions"),
                actions: [
                    HermexPopoverMenuAction(id: "share", title: "Share", systemImage: "square.and.arrow.up") {},
                    HermexPopoverMenuAction(id: "duplicate", title: "Duplicate", systemImage: "plus.square.on.square") {},
                    HermexPopoverMenuAction(id: "rename", title: "Rename", systemImage: "pencil") {}
                ]
            )
    }
}

private struct HermexOverlayLabPopoverAboveFlip: View {
    @State private var isPresented = false

    var body: some View {
        VStack {
            Spacer(minLength: 320)
            Button("Above flip (bottom anchor)") { isPresented = true }
                .accessibilityIdentifier("overlay-lab-popover-above-trigger")
                .hermexPopoverMenu(
                    isPresented: $isPresented,
                    accessibilityLabel: Text("Row actions"),
                    actions: [
                        HermexPopoverMenuAction(id: "share", title: "Share", systemImage: "square.and.arrow.up") {},
                        HermexPopoverMenuAction(id: "duplicate", title: "Duplicate", systemImage: "plus.square.on.square") {},
                        HermexPopoverMenuAction(id: "rename", title: "Rename", systemImage: "pencil") {}
                    ]
                )
        }
    }
}

// ─── 3. Horizontal clamp near each side edge ───────────────────────────────────
private struct HermexOverlayLabPopoverLeadingClamp: View {
    @State private var isPresented = false

    var body: some View {
        Button("Leading clamp") { isPresented = true }
            .accessibilityIdentifier("overlay-lab-popover-leading-trigger")
            .hermexPopoverMenu(
                isPresented: $isPresented,
                accessibilityLabel: Text("Row actions"),
                actions: [
                    HermexPopoverMenuAction(id: "pin", title: "Pin", systemImage: "pin") {},
                    HermexPopoverMenuAction(id: "archive", title: "Archive", systemImage: "archivebox") {}
                ]
            )
    }
}

private struct HermexOverlayLabPopoverTrailingClamp: View {
    @State private var isPresented = false

    var body: some View {
        Button("Trailing clamp") { isPresented = true }
            .accessibilityIdentifier("overlay-lab-popover-trailing-trigger")
            .hermexPopoverMenu(
                isPresented: $isPresented,
                accessibilityLabel: Text("Row actions"),
                actions: [
                    HermexPopoverMenuAction(id: "pin", title: "Pin", systemImage: "pin") {},
                    HermexPopoverMenuAction(id: "archive", title: "Archive", systemImage: "archivebox") {}
                ]
            )
    }
}

// ─── 4. Long action list: internal scroll keeps the last action reachable ─────
private struct HermexOverlayLabPopoverLongScroll: View {
    @State private var isPresented = false
    @State private var lastActionRunCount = 0

    private var actions: [HermexPopoverMenuAction] {
        (1...12).map { index in
            index == 12
                ? HermexPopoverMenuAction(id: "last", title: "Last action") { lastActionRunCount += 1 }
                : HermexPopoverMenuAction(id: index, title: "Action \(index)") {}
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Long list (internal scroll)") { isPresented = true }
                .accessibilityIdentifier("overlay-lab-popover-long-scroll-trigger")
                .hermexPopoverMenu(isPresented: $isPresented, accessibilityLabel: Text("Row actions"), actions: actions)
            Text(verbatim: "Last action ran \(lastActionRunCount) times")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("overlay-lab-popover-long-scroll-count")
        }
    }
}

// ─── 5. Disabled first row: initial focus moves to the next enabled row ───────
private struct HermexOverlayLabPopoverDisabledFirstRow: View {
    @State private var isPresented = false

    var body: some View {
        Button("Disabled first row") { isPresented = true }
            .accessibilityIdentifier("overlay-lab-popover-disabled-first-trigger")
            .hermexPopoverMenu(
                isPresented: $isPresented,
                accessibilityLabel: Text("Row actions"),
                actions: [
                    HermexPopoverMenuAction(id: "unavailable", title: "Unavailable", isEnabled: false) {},
                    HermexPopoverMenuAction(id: "available", title: "Available") {}
                ]
            )
    }
}

// ─── 6. Destructive row semantics ──────────────────────────────────────────────
private struct HermexOverlayLabPopoverDestructiveRow: View {
    @State private var isPresented = false

    var body: some View {
        Button("Destructive row") { isPresented = true }
            .accessibilityIdentifier("overlay-lab-popover-destructive-trigger")
            .hermexPopoverMenu(
                isPresented: $isPresented,
                accessibilityLabel: Text("Row actions"),
                actions: [
                    HermexPopoverMenuAction(id: "duplicate", title: "Duplicate", systemImage: "plus.square.on.square") {},
                    HermexPopoverMenuAction(id: "delete", title: "Delete", systemImage: "trash", role: .destructive) {}
                ]
            )
    }
}

// ─── 7. Outside-tap dismissal: the action counter never advances ──────────────
private struct HermexOverlayLabPopoverOutsideTapDismiss: View {
    @State private var isPresented = false
    @State private var actionRunCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Outside-tap dismissal") { isPresented = true }
                .accessibilityIdentifier("overlay-lab-popover-outside-tap-trigger")
                .hermexPopoverMenu(
                    isPresented: $isPresented,
                    accessibilityLabel: Text("Row actions"),
                    actions: [HermexPopoverMenuAction(id: "run", title: "Run") { actionRunCount += 1 }]
                )
            Text(verbatim: "Action ran \(actionRunCount) times")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("overlay-lab-popover-outside-tap-count")
        }
    }
}

// ─── 8. Dismiss-then-run counter: the action only changes after exit ──────────
private struct HermexOverlayLabPopoverDismissThenRun: View {
    @State private var isPresented = false
    @State private var actionRunCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Dismiss-then-run counter") { isPresented = true }
                .accessibilityIdentifier("overlay-lab-popover-dismiss-then-run-trigger")
                .hermexPopoverMenu(
                    isPresented: $isPresented,
                    accessibilityLabel: Text("Row actions"),
                    actions: [HermexPopoverMenuAction(id: "archive", title: "Archive") { actionRunCount += 1 }]
                )
            Text(verbatim: "Action ran \(actionRunCount) times")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("overlay-lab-popover-dismiss-then-run-count")
        }
    }
}

// ─── 9. Largest supported accessibility Dynamic Type size ─────────────────────
private struct HermexOverlayLabPopoverAccessibilitySize: View {
    @State private var isPresented = false

    var body: some View {
        Button("Largest accessibility text size") { isPresented = true }
            .accessibilityIdentifier("overlay-lab-popover-accessibility-size-trigger")
            .hermexPopoverMenu(
                isPresented: $isPresented,
                accessibilityLabel: Text("Row actions"),
                actions: [
                    HermexPopoverMenuAction(id: "share", title: "Share", systemImage: "square.and.arrow.up") {},
                    HermexPopoverMenuAction(id: "delete", title: "Delete", systemImage: "trash", role: .destructive) {}
                ]
            )
            .dynamicTypeSize(.accessibility5)
    }
}

// ─── 10. Rotation while visible and Reduce Motion/Transparency ─────────────────
// Rotate the simulator while any fixture above is open to exercise
// `HermexPopoverPlacement`'s live recompute; Reduce Motion/Transparency are forced
// globally by the lab's own toggles (`controls`), so every fixture above exercises both.

// ─── Batch B follow-up fixtures ─────────────────────────────────────────────────
// Rendered-verification specimens for shared components whose source contract changed in Batch B
// (DSF-07..DSF-09). These exist to confirm the changes render correctly on device/simulator, not to
// adopt the components at any production call site.

// ─── Card: every real surface variant, translucent Request Card over an intentional scrim ─────
private struct HermexOverlayLabCardFollowup: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "Card (surface variants)").font(.subheadline.weight(.semibold))

            Text(verbatim: "Glass surface")
                .font(.body)
                .padding(HermexCardMetrics.contentPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .hermexCardSurface(.glass)
                .accessibilityIdentifier("overlay-lab-batch-b-card-glass")

            Text(verbatim: "Outlined surface")
                .font(.body)
                .padding(HermexCardMetrics.contentPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .hermexCardSurface(.outlined)
                .accessibilityIdentifier("overlay-lab-batch-b-card-outlined")

            Text(verbatim: "Compact card surface")
                .font(.body)
                .padding(HermesSpacing.s12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .compactCardSurface()
                .accessibilityIdentifier("overlay-lab-batch-b-card-compact")

            Text(verbatim: "Request card, opaque")
                .font(.body)
                .padding(HermexCardMetrics.contentPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .requestCardSurface(cornerRadius: HermesRadius.card, material: .opaque)
                .accessibilityIdentifier("overlay-lab-batch-b-card-request-opaque")

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "Request card, translucent over scrim")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ZStack {
                    RoundedRectangle(cornerRadius: HermesRadius.card, style: .continuous)
                        .fill(Color.blue.opacity(0.4))
                        .frame(height: 96)
                    Text(verbatim: "Approve this request?")
                        .font(.body)
                        .padding(HermexCardMetrics.contentPadding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .requestCardSurface(cornerRadius: HermesRadius.card, material: .translucentOverScrim)
                        .padding(.horizontal, HermesSpacing.s16)
                }
            }
            .accessibilityIdentifier("overlay-lab-batch-b-card-request-translucent")
        }
        .accessibilityIdentifier("overlay-lab-batch-b-card-section")
    }
}

// ─── Accordion List: header/body text-column and divider alignment specimen (DSR2-02) ─────────
private struct HermexOverlayLabAccordionFollowup: View {
    private struct Group: Identifiable {
        let id: String
        let title: String
        let rows: [Row]
    }

    private struct Row: Identifiable {
        let id: String
        let title: String
    }

    private let groups = [
        Group(
            id: "hermex",
            title: "Hermex",
            rows: [
                Row(id: "session-1", title: "Investigate flaky test"),
                Row(id: "session-2", title: "Refactor auth module")
            ]
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "Accordion List (header/body alignment)").font(.subheadline.weight(.semibold))
            AccordionList(
                items: groups,
                appearance: .card,
                separatorStyle: .betweenRows,
                expansion: .localSingle(initiallyExpanded: "hermex"),
                bodyItems: { $0.rows },
                headerTitle: { Text($0.title) },
                headerSubtitle: { Text("\($0.rows.count) sessions") },
                headerAccessibilityLabel: { Text($0.title) },
                headerIsDisabled: { _ in false },
                headerLeading: { _ in HermexAvatar(systemImage: "folder", size: .small) },
                headerTitleAccessory: { _ in EmptyView() },
                bodyItem: { _, row in ListItem(title: Text(row.title), action: {}) }
            )
            .accessibilityIdentifier("overlay-lab-batch-b-accordion-card")
        }
    }
}

// ─── Accordion List: no-leading Card/Cardless specimens using the HeaderLeading == EmptyView
// initializer seam (Round 3) — the leading-present Card specimen above is unchanged. ─────────────
private struct HermexOverlayLabAccordionNoLeadingFollowup: View {
    private struct Group: Identifiable {
        let id: String
        let title: String
        let rows: [Row]
    }

    private struct Row: Identifiable {
        let id: String
        let title: String
    }

    private let groups = [
        Group(
            id: "hermex-no-leading",
            title: "Hermex",
            rows: [
                Row(id: "session-1", title: "Investigate flaky test"),
                Row(id: "session-2", title: "Refactor auth module")
            ]
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "Accordion List (no-leading)").font(.subheadline.weight(.semibold))

            Text(verbatim: "Card").font(.caption).foregroundStyle(.secondary)
            AccordionList(
                items: groups,
                appearance: .card,
                separatorStyle: .betweenRows,
                expansion: .localSingle(initiallyExpanded: "hermex-no-leading"),
                bodyItems: { $0.rows },
                headerTitle: { Text($0.title) },
                headerSubtitle: { Text("\($0.rows.count) sessions") },
                headerAccessibilityLabel: { Text($0.title) },
                headerIsDisabled: { _ in false },
                headerTitleAccessory: { _ in EmptyView() },
                bodyItem: { _, row in ListItem(title: Text(row.title), action: {}) }
            )
            .accessibilityIdentifier("overlay-lab-round-3-accordion-no-leading-card")

            Text(verbatim: "Cardless").font(.caption).foregroundStyle(.secondary)
            AccordionList(
                items: groups,
                appearance: .cardless,
                separatorStyle: .betweenRows,
                expansion: .localSingle(initiallyExpanded: nil),
                bodyItems: { $0.rows },
                headerTitle: { Text($0.title) },
                headerSubtitle: { Text("\($0.rows.count) sessions") },
                headerAccessibilityLabel: { Text($0.title) },
                headerIsDisabled: { _ in false },
                headerTitleAccessory: { _ in EmptyView() },
                bodyItem: { _, row in ListItem(title: Text(row.title), action: {}) }
            )
            .accessibilityIdentifier("overlay-lab-round-3-accordion-no-leading-cardless")
        }
        .accessibilityIdentifier("overlay-lab-round-3-accordion-no-leading-section")
    }
}

// ─── List Item: press-and-hold rounded feedback, standard vs. indicator-only selected chrome,
// disabled, and pending — inside a padded/outlined Card (Round 3, rendered verification only). ────
private struct HermexOverlayLabListItemFollowup: View {
    var body: some View {
        VStack(alignment: .leading, spacing: HermesSpacing.s8) {
            Text(verbatim: "List Item (rendered verification)").font(.subheadline.weight(.semibold))

            ListItem(title: Text(verbatim: "Normal row"), action: {})
                .accessibilityIdentifier("overlay-lab-round-3-list-item-normal")

            Text(verbatim: "Press and hold for rounded background feedback")
                .font(.caption)
                .foregroundStyle(.secondary)
            ListItem(
                title: Text(verbatim: "Interactive row"),
                action: {}
            )
            .accessibilityIdentifier("overlay-lab-round-3-list-item-interactive")

            ListItem(
                title: Text(verbatim: "Selected (standard chrome)"),
                state: ListItemState(isSelected: true),
                action: {}
            )
            .accessibilityIdentifier("overlay-lab-round-3-list-item-selected-standard")

            ListItem(
                title: Text(verbatim: "Selected (indicator-only chrome)"),
                state: ListItemState(isSelected: true),
                selectionChrome: .indicatorOnly,
                action: {},
                leading: { HermexRadio(isSelected: true, action: nil) }
            )
            .accessibilityIdentifier("overlay-lab-round-3-list-item-selected-indicator-only")

            ListItem(
                title: Text(verbatim: "Disabled row"),
                state: ListItemState(isDisabled: true),
                action: {}
            )
            .accessibilityIdentifier("overlay-lab-round-3-list-item-disabled")

            ListItem(
                title: Text(verbatim: "Pending row"),
                state: ListItemState(isPending: true),
                action: {}
            )
            .accessibilityIdentifier("overlay-lab-round-3-list-item-pending")
        }
        .padding(HermexCardMetrics.contentPadding)
        .hermexCardSurface(.outlined)
        .accessibilityIdentifier("overlay-lab-round-3-list-item-section")
    }
}

// ─── Selection controls: Radio and Checkbox, every real state plus a row-owned indicator ──────
private struct HermexOverlayLabSelectionControlsFollowup: View {
    @State private var rowOwnedIsChecked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "Selection controls (Radio, Checkbox)").font(.subheadline.weight(.semibold))

            HermexRadio(isSelected: false, label: "Unselected option") {}
                .accessibilityIdentifier("overlay-lab-batch-b-radio-unselected")
            HermexRadio(isSelected: true, label: "Selected option") {}
                .accessibilityIdentifier("overlay-lab-batch-b-radio-selected")
            HermexRadio(isSelected: true, isEnabled: false, label: "Disabled, selected option") {}
                .accessibilityIdentifier("overlay-lab-batch-b-radio-disabled-selected")

            HermexCheckbox(isChecked: false, label: "Unchecked option") {}
                .accessibilityIdentifier("overlay-lab-batch-b-checkbox-unchecked")
            HermexCheckbox(isChecked: true, label: "Checked option") {}
                .accessibilityIdentifier("overlay-lab-batch-b-checkbox-checked")
            HermexCheckbox(isChecked: true, isEnabled: false, label: "Disabled, checked option") {}
                .accessibilityIdentifier("overlay-lab-batch-b-checkbox-disabled-checked")

            Button {
                rowOwnedIsChecked.toggle()
            } label: {
                HStack(spacing: HermesSpacing.s8) {
                    HermexCheckbox(isChecked: rowOwnedIsChecked, action: nil)
                    Text(verbatim: "Row-owned checkbox (enclosing Button owns the tap)")
                        .font(.body)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("overlay-lab-batch-b-checkbox-row-owned")
        }
        .accessibilityIdentifier("overlay-lab-batch-b-selection-controls-section")
    }
}

// ─── Search follow-up fixtures ──────────────────────────────────────────────────
// Rendered-verification specimens for the custom Search foundation (DSF-05): the direct field,
// its disabled state, and the `.hermexSearch(...)` convenience modifier's persistent top inset
// geometry. These exist to confirm the shared component renders and behaves correctly on
// device/simulator, not to adopt Search at any production call site.
private struct HermexOverlayLabSearchFollowup: View {
    @State private var query = "Investigate"
    @State private var submitCount = 0

    private let sampleSessions = ["Investigate flaky test", "Refactor auth module", "Update onboarding copy"]

    var body: some View {
        let submitUnit = submitCount == 1 ? "time" : "times"

        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "Direct field").font(.subheadline.weight(.semibold))
            HermexSearchField(
                "Search sessions",
                text: $query,
                prompt: Text("Search sessions"),
                onSubmit: { submitCount += 1 }
            )
            .accessibilityIdentifier("overlay-lab-search-field")
            Text(verbatim: "Query: \"\(query)\" — submitted \(submitCount) \(submitUnit)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("overlay-lab-search-field-evidence")

            HermexSearchField(
                "Disabled search",
                text: .constant("Read only"),
                isEnabled: false
            )
            .accessibilityIdentifier("overlay-lab-search-field-disabled")

            Text(verbatim: "Convenience modifier (top inset)").font(.subheadline.weight(.semibold))
            List(sampleSessions.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }, id: \.self) { session in
                Text(session)
            }
            .frame(height: 160)
            .hermexSearch("Search sessions", text: $query, prompt: Text("Search sessions"))
            .accessibilityIdentifier("overlay-lab-search-modifier-list")
        }
    }
}

// ─── Selection Sheet follow-up fixtures ─────────────────────────────────────────
// Rendered-verification specimens for the caller-presented Selection Sheet foundation (Issue #607,
// DSF-06), which replaced the retired `HermexDropdown`. Each fixture owns its own `.sheet` and
// detents — the component itself never presents — so these also prove the component does not.
// These exist to confirm the shared component renders and behaves correctly on device/simulator,
// not to adopt it at any production call site.

private enum HermexOverlayLabProvider: String, Hashable, CaseIterable {
    case anthropic = "Anthropic"
    case openai = "OpenAI"
    case google = "Google"
}

// ─── Single selection: current value, immediate commit, disabled option ───────
private struct HermexOverlayLabSelectionSheetSingle: View {
    @State private var isPresented = ProcessInfo.processInfo.arguments.contains(
        "--hermex-overlay-lab-auto-selection-sheet-single"
    )
    @State private var selection: HermexOverlayLabProvider? = .anthropic

    private var options: [HermexSelectionSheetOption<HermexOverlayLabProvider>] {
        [
            HermexSelectionSheetOption(value: .anthropic, title: "Anthropic"),
            HermexSelectionSheetOption(value: .openai, title: "OpenAI"),
            HermexSelectionSheetOption(value: .google, title: "Google", isEnabled: false)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Single selection") { isPresented = true }
                .accessibilityIdentifier("overlay-lab-selection-sheet-single-trigger")
            Text(verbatim: "Committed: \(selection?.rawValue ?? "None")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("overlay-lab-selection-sheet-single-committed")
        }
        .accessibilityIdentifier("overlay-lab-selection-sheet-single")
        .sheet(isPresented: $isPresented) {
            HermexSelectionSheet("Default Provider", selection: $selection, options: options)
                .presentationDetents([.medium, .large])
        }
    }
}

// ─── Multi selection, horizontal footer: two-value baseline, staged draft, Cancel, Done ────────
private struct HermexOverlayLabSelectionSheetMultiHorizontal: View {
    @State private var isPresented = ProcessInfo.processInfo.arguments.contains(
        "--hermex-overlay-lab-auto-selection-sheet-multi"
    )
    @State private var selections: Set<HermexOverlayLabProvider> = [.anthropic, .openai]

    private var options: [HermexSelectionSheetOption<HermexOverlayLabProvider>] {
        [
            HermexSelectionSheetOption(value: .anthropic, title: "Anthropic"),
            HermexSelectionSheetOption(value: .openai, title: "OpenAI"),
            HermexSelectionSheetOption(value: .google, title: "Google")
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Multi selection (horizontal footer)") { isPresented = true }
                .accessibilityIdentifier("overlay-lab-selection-sheet-multi-horizontal-trigger")
            Text(verbatim: "Committed: \(selections.map(\.rawValue).sorted().joined(separator: ", "))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("overlay-lab-selection-sheet-multi-horizontal-committed")
        }
        .accessibilityIdentifier("overlay-lab-selection-sheet-multi-horizontal")
        .sheet(isPresented: $isPresented) {
            HermexSelectionSheet(
                "Model Providers",
                selections: $selections,
                options: options,
                footerAxis: .horizontal
            )
            .presentationDetents([.medium, .large])
        }
    }
}

// ─── Multi selection, vertical footer: its own state, trigger, and committed-value evidence ───
private struct HermexOverlayLabSelectionSheetMultiVertical: View {
    @State private var isPresented = ProcessInfo.processInfo.arguments.contains(
        "--hermex-overlay-lab-auto-selection-sheet-multi-vertical"
    )
    @State private var selections: Set<HermexOverlayLabProvider> = [.anthropic]

    private var options: [HermexSelectionSheetOption<HermexOverlayLabProvider>] {
        [
            HermexSelectionSheetOption(value: .anthropic, title: "Anthropic"),
            HermexSelectionSheetOption(value: .openai, title: "OpenAI"),
            HermexSelectionSheetOption(value: .google, title: "Google")
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Multi selection (vertical footer)") { isPresented = true }
                .accessibilityIdentifier("overlay-lab-selection-sheet-multi-vertical-trigger")
            Text(verbatim: "Committed: \(selections.map(\.rawValue).sorted().joined(separator: ", "))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("overlay-lab-selection-sheet-multi-vertical-committed")
        }
        .accessibilityIdentifier("overlay-lab-selection-sheet-multi-vertical")
        .sheet(isPresented: $isPresented) {
            HermexSelectionSheet(
                "Model Providers",
                selections: $selections,
                options: options,
                footerAxis: .vertical
            )
            .presentationDetents([.medium, .large])
        }
    }
}

// ─── Optional caller-controlled Search: filtered options and no-results state ─
private struct HermexOverlayLabSelectionSheetSearch: View {
    @State private var isPresented = false
    @State private var selection: HermexOverlayLabProvider?
    @State private var query = ""

    private var visibleOptions: [HermexSelectionSheetOption<HermexOverlayLabProvider>] {
        HermexOverlayLabProvider.allCases
            .filter { query.isEmpty || $0.rawValue.localizedCaseInsensitiveContains(query) }
            .map { HermexSelectionSheetOption(value: $0, title: LocalizedStringKey($0.rawValue)) }
    }

    var body: some View {
        Button("Search + no-results") { isPresented = true }
            .accessibilityIdentifier("overlay-lab-selection-sheet-search-trigger")
            .sheet(isPresented: $isPresented) {
                HermexSelectionSheet(
                    "Search Providers",
                    selection: $selection,
                    options: visibleOptions,
                    search: HermexSelectionSheetSearch(title: "Search providers", text: $query)
                )
                .presentationDetents([.medium, .large])
            }
    }
}

// ─── No-inset: composed inside a pre-padded Card, contentInset: .none avoids double inset ─────
private struct HermexOverlayLabSelectionSheetNoInset: View {
    @State private var isPresented = false
    @State private var selection: HermexOverlayLabProvider? = .anthropic

    private var options: [HermexSelectionSheetOption<HermexOverlayLabProvider>] {
        [
            HermexSelectionSheetOption(value: .anthropic, title: "Anthropic"),
            HermexSelectionSheetOption(value: .openai, title: "OpenAI"),
            HermexSelectionSheetOption(value: .google, title: "Google")
        ]
    }

    var body: some View {
        Button("No inset (inside pre-padded Card)") { isPresented = true }
            .padding(HermexCardMetrics.contentPadding)
            .hermexCardSurface(.outlined)
            .accessibilityIdentifier("overlay-lab-selection-sheet-no-inset")
            .sheet(isPresented: $isPresented) {
                HermexSelectionSheet(
                    "Default Provider",
                    selection: $selection,
                    options: options,
                    contentInset: .none
                )
                .presentationDetents([.medium, .large])
            }
    }
}

// ─── Long list: 20+ options, internally scrolling ──────────────────────────────
private struct HermexOverlayLabSelectionSheetLongList: View {
    @State private var isPresented = false
    @State private var selection: Int?

    private var options: [HermexSelectionSheetOption<Int>] {
        (1...24).map { HermexSelectionSheetOption(value: $0, title: "Option \($0)") }
    }

    var body: some View {
        Button("Long list (24 options)") { isPresented = true }
            .accessibilityIdentifier("overlay-lab-selection-sheet-long-list-trigger")
            .sheet(isPresented: $isPresented) {
                HermexSelectionSheet("Choose an Option", selection: $selection, options: options)
                    .presentationDetents([.medium, .large])
            }
    }
}

// ─── Text Input follow-up fixtures ──────────────────────────────────────────────
// Rendered-verification specimens for the Text Input foundation's final Default/Password/Code
// taxonomy (Issue #607, DSR2-06): real `HermexTextField`/`HermexSecureField`/`HermexCodeInput`
// specimens at 4/6/8-digit lengths and partial/complete/error/disabled states, none of which
// auto-submit. These exist to confirm the shared components render and behave correctly on
// device/simulator, not to adopt them at any production call site.
private struct HermexOverlayLabTextInputFollowup: View {
    @State private var name = ""
    @State private var password = ""
    @State private var code4 = "12"
    @State private var code6Partial = "123"
    @State private var code6Complete = "123456"
    @State private var code6Error = "12345"
    @State private var code6Disabled = "123456"
    @State private var code8 = "12345678"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: "Default").font(.subheadline.weight(.semibold))
            HermexTextField("Name", text: $name, prompt: Text("Enter your name"))
                .accessibilityIdentifier("overlay-lab-text-input-default")

            Text(verbatim: "Password").font(.subheadline.weight(.semibold))
            HermexSecureField("Password", text: $password, prompt: Text("Enter your password"))
                .accessibilityIdentifier("overlay-lab-text-input-password")

            Text(verbatim: "Code (4 digits)").font(.subheadline.weight(.semibold))
            HermexCodeInput("Verification code", code: $code4, length: 4)
                .accessibilityIdentifier("overlay-lab-code-input-4")

            Text(verbatim: "Code (6 digits, partial)").font(.subheadline.weight(.semibold))
            HermexCodeInput("Verification code", code: $code6Partial, length: 6)
                .accessibilityIdentifier("overlay-lab-code-input-6-partial")

            Text(verbatim: "Code (6 digits, complete)").font(.subheadline.weight(.semibold))
            HermexCodeInput("Verification code", code: $code6Complete, length: 6)
                .accessibilityIdentifier("overlay-lab-code-input-6-complete")

            Text(verbatim: "Code (6 digits, error)").font(.subheadline.weight(.semibold))
            HermexCodeInput(
                "Verification code",
                code: $code6Error,
                length: 6,
                errorText: Text(verbatim: "Enter all 6 digits.")
            )
            .accessibilityIdentifier("overlay-lab-code-input-error")

            Text(verbatim: "Code (6 digits, disabled)").font(.subheadline.weight(.semibold))
            HermexCodeInput("Verification code", code: $code6Disabled, length: 6, isEnabled: false)
                .accessibilityIdentifier("overlay-lab-code-input-disabled")

            Text(verbatim: "Code (8 digits)").font(.subheadline.weight(.semibold))
            HermexCodeInput("Recovery code", code: $code8, length: 8)
                .accessibilityIdentifier("overlay-lab-code-input-8")
        }
    }
}
#endif
