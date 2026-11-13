import SwiftUI
import UIKit

enum KanbanCardAction: Equatable {
    case move(String)
    case block
    case unblock
    /// Done, with what was done when the server needs it; nil asks for it when it does.
    case complete(result: String?)
    case archive
}

enum KanbanCardRowPrimaryAction: Equatable {
    case openDetail(String)
    case toggleSelection(String)

    static func resolve(for card: KanbanCard, isSelecting: Bool) -> Self? {
        guard let cardID = card.cardID else { return nil }
        return isSelecting ? .toggleSelection(cardID) : .openDetail(cardID)
    }

    static func focusTarget(afterDismissing cardID: String, visibleCards: [KanbanCard]) -> String? {
        visibleCards.contains { $0.cardID == cardID } ? cardID : nil
    }
}

struct KanbanPendingCardAction: Identifiable, Equatable {
    let id = UUID()
    let card: KanbanCard
    let action: KanbanCardAction

    static func == (lhs: KanbanPendingCardAction, rhs: KanbanPendingCardAction) -> Bool {
        lhs.id == rhs.id
    }
}

extension View {
    /// Asks what was done before a Hermes host completes `card` outside Review (#1677), and
    /// stands in for "Leave Running?" on a Running Card: Complete confirms both.
    func kanbanCompletionPrompt(
        card: Binding<KanbanCard?>,
        onComplete: @escaping (KanbanCard, String) -> Void
    ) -> some View {
        modifier(KanbanCompletionPrompt(card: card, onComplete: onComplete))
    }
}

private struct KanbanCompletionPrompt: ViewModifier {
    @Binding var card: KanbanCard?
    let onComplete: (KanbanCard, String) -> Void
    @State private var note = ""

    func body(content: Content) -> some View {
        content
            .alert(
                "Complete Card?",
                isPresented: Binding(get: { card != nil }, set: { if !$0 { card = nil } }),
                presenting: card
            ) { card in
                TextField("What was done?", text: $note)
                Button("Cancel", role: .cancel) {}
                Button("Complete") { onComplete(card, note) }
                    .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: { card in
                let running = card.status?.rawValue == "running"
                Text(verbatim: [
                    String(localized: "Hermes saves this as the Card's result."),
                    running ? String(localized: "Leaving Running may clear the Card's claim and worker state.") : nil
                ].compactMap { $0 }.joined(separator: " "))
            }
            .onChange(of: card?.cardID) { _, cardID in
                if cardID != nil { note = "" }
            }
    }
}

enum KanbanDispatcherPresentation {
    static func hasResult(_ state: KanbanDispatchState?) -> Bool {
        guard let state, state.result != nil else { return false }
        switch state.phase {
        case .succeeded, .outcomeUncertain:
            return true
        case .submitting, .reconciling, .refused, .failed, .boardUnavailable:
            return false
        }
    }

    static func requiresAttention(_ state: KanbanDispatchState?) -> Bool {
        state?.phase == .outcomeUncertain && state?.result == nil
    }

    static func toolbarSystemImage(for state: KanbanDispatchState?) -> String {
        if requiresAttention(state) {
            return "exclamationmark.circle.fill"
        }
        if hasResult(state) {
            return "bolt.horizontal.circle.fill"
        }
        return "bolt.horizontal.circle"
    }

    static func toolbarAccessibilityLabel(for state: KanbanDispatchState?) -> String {
        if requiresAttention(state) {
            return String(localized: "Dispatcher, attention required")
        }
        if hasResult(state) {
            return String(localized: "Dispatcher, result available")
        }
        return String(localized: "Dispatcher")
    }
}

/// Icons for the Kanban header's overflow slot, which keeps Select Cards and Card
/// Filters behind a More menu and flips to a filled glyph while a filter is applied.
enum KanbanHeaderPresentation {
    static func overflowSystemImage(hasActiveFilters: Bool) -> String {
        hasActiveFilters ? "ellipsis.circle.fill" : "ellipsis.circle"
    }

    static func cardFiltersSystemImage(hasActiveFilters: Bool) -> String {
        hasActiveFilters
            ? "line.3.horizontal.decrease.circle.fill"
            : "line.3.horizontal.decrease.circle"
    }

    /// Widest the Board picker may ever ask to be, so the navigation bar always has
    /// room for it beside the back button and the trailing group.
    ///
    /// Measured on iPhone 17 (402pt wide, default text size) from the short-name
    /// layout: the back button occupies x≈16-60 and the principal item starts at
    /// x≈72, so the leading side costs 16 (margin) + 44 (button) + 12 (gap) = 72pt.
    /// The trailing glass pill occupies x≈218-386, i.e. 168pt for three 44pt controls
    /// plus the pill's padding, and costs another 16 (margin) + 12 (gap) = 28pt. That
    /// leaves ~134pt of usable gap at 402pt wide, and a reserve of ~268pt.
    ///
    /// Only the pill scales with Dynamic Type (`trailingGroupWidth`); the fixed 100pt
    /// of margins and gaps does not. The 80pt floor keeps the picker tappable on the
    /// narrowest device and covers the first layout pass, where `barWidth` is still 0.
    static func boardPickerMaxWidth(barWidth: CGFloat, trailingGroupWidth: CGFloat) -> CGFloat {
        let leadingReserve: CGFloat = 72
        let trailingReserve = min(trailingGroupWidth, 168 * 1.4) + 28
        return max(80, barWidth - leadingReserve - trailingReserve)
    }
}

@MainActor
struct KanbanFiltersDraft {
    var profile: String?
    var tenant: String?
    var includesArchived: Bool
    var onlyMine: Bool
    var groupsByProfile: Bool

    init(model: KanbanFeatureState) {
        profile = model.selectedProfile
        tenant = model.selectedTenant
        includesArchived = model.includeArchived
        onlyMine = model.onlyMine
        groupsByProfile = model.groupByProfile
    }

    func apply(to model: KanbanFeatureState) async {
        let serverFiltersChanged = profile != model.selectedProfile
            || tenant != model.selectedTenant
            || includesArchived != model.includeArchived
            || onlyMine != model.onlyMine
        model.groupByProfile = groupsByProfile
        guard serverFiltersChanged else { return }
        await model.applyFilters(
            profile: profile,
            tenant: tenant,
            includeArchived: includesArchived,
            onlyMine: onlyMine
        )
    }
}

struct KanbanStatusFocusView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var model: KanbanFeatureState
    @State private var showsFilters = false
    @State private var showsBoardManagement = false
    @State private var visibleModel: KanbanFeatureState?
    @State private var cardEditor: KanbanCardEditorState?
    @State private var pendingRunningAction: KanbanPendingCardAction?
    @State private var pendingCompletion: KanbanCard?
    @State private var showsBulkActions = false
    @State private var confirmsBulkArchive = false
    @State private var confirmsRunDispatcher = false
    @State private var showsDispatcher = false
    @State private var presentedCardID: String?
    /// Width of the screen, measured on the content view and used to cap the Board
    /// picker so the navigation bar never drops it. See `boardPickerMaxWidth`.
    @State private var barWidth: CGFloat = 0
    /// The trailing glass pill's width at the current text size. Its base is the
    /// measured 168pt (three 44pt controls plus the pill's own padding) on iPhone 17
    /// at the default text size; nav-bar glyphs grow with Dynamic Type but stop well
    /// before AX5, so `boardPickerMaxWidth` clamps this to 1.4x the base.
    @ScaledMetric(relativeTo: .body) private var trailingGroupWidth: CGFloat = 168
    @AccessibilityFocusState private var focusedCardID: String?
    @AccessibilityFocusState private var archiveUndoIsFocused: Bool
    @AccessibilityFocusState private var selectionControlsAreFocused: Bool
    @AccessibilityFocusState private var bulkSummaryIsFocused: Bool
    @AccessibilityFocusState private var dispatchSummaryIsFocused: Bool
    @AccessibilityFocusState private var dispatcherButtonIsFocused: Bool

    var body: some View {
        Group {
            switch model.state {
            case .idle, .checking:
                loadingContent
            case .compatible, .partial:
                boardContent
            case .authenticationRequired:
                unavailableContent(
                    title: String(localized: "Sign in is required for Kanban."),
                    detail: String(localized: "Return to the server login screen, then try again."),
                    systemImage: "lock"
                )
            case .networkUnavailable:
                unavailableContent(
                    title: String(localized: "Kanban could not reach the server."),
                    detail: String(localized: "Check your connection, then try again."),
                    systemImage: "wifi.exclamationmark"
                )
            case .serverUnavailable:
                unavailableContent(
                    title: String(localized: "The Kanban server is unavailable."),
                    detail: String(localized: "Check that the Hermes server is awake, then try again."),
                    systemImage: "server.rack"
                )
            case .incompatibleContract:
                unavailableContent(
                    title: String(localized: "This server's Kanban response is incompatible with Hermex."),
                    detail: String(localized: "No Kanban changes were made."),
                    systemImage: "exclamationmark.triangle"
                )
            case .unavailable:
                unavailableContent(
                    title: String(localized: "Kanban isn’t available on this server."),
                    detail: String(localized: "Turn on the Kanban plugin on the Hermes host, then try again."),
                    systemImage: "puzzlepiece.extension"
                )
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            barWidth = width
        }
        .navigationDestination(item: $presentedCardID) { cardID in
            KanbanCardDetailView(featureModel: model, cardID: cardID)
        }
        .themedPageBackground()
        .navigationTitle(String(localized: "Kanban"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $model.searchText, prompt: Text("Search Cards"))
        .toolbar { toolbarContent }
        .sheet(isPresented: $showsFilters) {
            KanbanFiltersView(model: model)
        }
        .sheet(isPresented: $showsDispatcher, onDismiss: {
            dispatcherButtonIsFocused = true
        }) {
            dispatcherSheet
        }
        .sheet(isPresented: $showsBoardManagement) {
            NavigationStack {
                KanbanBoardManagementView(model: model)
            }
        }
        .sheet(item: $cardEditor) { editor in
            KanbanCardEditorView(
                state: editor,
                allowsMutation: editor.isEditing ? model.canEditCards : model.canCreateCards,
                onSaved: { await model.reconcileAfterCardMutation(notice: editor.notice) }
            )
        }
        .sheet(isPresented: $showsBulkActions, onDismiss: {
            selectionControlsAreFocused = true
        }) {
            KanbanBulkActionsView(
                model: model,
                onArchive: {
                    showsBulkActions = false
                    confirmsBulkArchive = true
                },
                onFinished: {
                    showsBulkActions = false
                    bulkSummaryIsFocused = true
                }
            )
        }
        .onAppear { activateCurrentModel() }
        .onDisappear {
            visibleModel?.setVisible(false)
            visibleModel = nil
        }
        .onChange(of: ObjectIdentifier(model)) { _, _ in
            activateCurrentModel()
            updateSceneActivity(scenePhase)
        }
        .onChange(of: scenePhase) { _, phase in
            updateSceneActivity(phase)
        }
        .onChange(of: model.isRefreshing) { wasRefreshing, isRefreshing in
            if wasRefreshing, !isRefreshing, model.isSelectingCards {
                selectionControlsAreFocused = true
            }
        }
        .onChange(of: model.dispatchState?.phase) { oldPhase, newPhase in
            if oldPhase?.isInFlight == true, newPhase?.isInFlight == false {
                if showsDispatcher {
                    dispatchSummaryIsFocused = true
                } else {
                    dispatcherButtonIsFocused = true
                }
            }
        }
        .onChange(of: presentedCardID) { previousCardID, currentCardID in
            guard currentCardID == nil, let previousCardID else { return }
            Task { @MainActor in
                await Task.yield()
                focusedCardID = KanbanCardRowPrimaryAction.focusTarget(
                    afterDismissing: previousCardID,
                    visibleCards: model.visibleCards
                )
            }
        }
        .alert(
            "Leave Running?",
            isPresented: Binding(
                get: { pendingRunningAction != nil },
                set: { if !$0 { pendingRunningAction = nil } }
            ),
            presenting: pendingRunningAction
        ) { pending in
            Button("Cancel", role: .cancel) { pendingRunningAction = nil }
            Button("Continue", role: .destructive) {
                pendingRunningAction = nil
                perform(pending.action, for: pending.card, confirmingRunningExit: true)
            }
        } message: { _ in
            Text("Leaving Running may clear the Card's claim and worker state.")
        }
        .kanbanCompletionPrompt(card: $pendingCompletion) { card, note in
            perform(.complete(result: note), for: card, confirmingRunningExit: true)
        }
        .alert("Archive Cards", isPresented: $confirmsBulkArchive) {
            Button("Cancel", role: .cancel) {
                selectionControlsAreFocused = true
            }
            Button("Archive Cards", role: .destructive) {
                Task {
                    await model.performBulkAction(.archiveCards)
                    bulkSummaryIsFocused = true
                }
            }
        } message: {
            Text("The selected Cards will be moved to the archive.")
        }
    }

    private func activateCurrentModel() {
        guard visibleModel !== model else {
            model.setVisible(true)
            return
        }
        visibleModel?.setVisible(false)
        visibleModel = model
        model.setVisible(true)
    }

    private func updateSceneActivity(_ phase: ScenePhase) {
        Task { await model.setScenePhase(phase) }
    }

    private var loadingContent: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading Kanban")
                .foregroundStyle(.appSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Loading Kanban"))
    }

    private var boardContent: some View {
        VStack(spacing: 0) {
            if model.state == .partial {
                compatibilityBanner
            }
            if model.isOffline {
                offlineBanner
            } else if model.liveUpdatesDelayed {
                liveUpdatesDelayedBanner
            }
            if model.refreshFailed {
                refreshErrorBanner
            }
            if model.hasAvailableArchiveUndo, let undo = model.archiveUndo {
                archiveUndoBanner(undo)
            }
            if let notice = model.cardNotice {
                cardNoticeBanner(notice)
            }
            if model.bulkActionPhase != nil {
                bulkProgressBanner
            } else if let summary = model.bulkActionSummary {
                bulkSummaryBanner(summary)
            }
            if model.requiresBoardSelection {
                boardSelectionContent
            } else {
                if model.isSelectingCards {
                    selectionControls
                }
                statusSelector
                Divider()
                cardList
            }
        }
    }

    private var dispatcherSheet: some View {
        NavigationStack {
            ScrollView {
                dispatcherPanel
                    .padding()
            }
            .themedPageBackground()
            .navigationTitle("Dispatcher")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showsDispatcher = false }
                }
            }
        }
        .themedPageBackground()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .alert("Run Dispatcher", isPresented: $confirmsRunDispatcher) {
            Button("Cancel", role: .cancel) {}
            Button("Run Dispatcher", role: .destructive) {
                Task { await model.runDispatcher() }
            }
        } message: {
            Text(KanbanDispatchCopy.runConfirmation)
        }
    }

    private var dispatcherPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    previewDispatchButton
                    runDispatcherButton
                }
                VStack(spacing: 8) {
                    previewDispatchButton
                        .frame(maxWidth: .infinity)
                    runDispatcherButton
                        .frame(maxWidth: .infinity)
                }
            }

            Text("Preview is advisory and may become stale. It never starts workers.")
                .font(AppFont.footnote())
                .foregroundStyle(.appSecondary)

            if let dispatcherUnavailableReason,
               model.dispatchState?.phase.isInFlight != true {
                Text(dispatcherUnavailableReason)
                    .font(AppFont.footnote())
                    .foregroundStyle(.appSecondary)
            }

            if let dispatch = model.dispatchState {
                Divider()
                dispatchSummary(dispatch)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var previewDispatchButton: some View {
        Button("Preview Dispatch") {
            Task { await model.previewDispatch() }
        }
        .buttonStyle(.bordered)
        .disabled(model.dispatcherAvailability != .available)
        .frame(minHeight: 44)
    }

    private var runDispatcherButton: some View {
        Button("Run Dispatcher") {
            confirmsRunDispatcher = true
        }
        .buttonStyle(.appProminent)
        .disabled(model.dispatcherAvailability != .available)
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private func dispatchSummary(_ dispatch: KanbanDispatchState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(dispatchModeTitle(dispatch.mode))
                    .font(AppFont.subheadline(weight: .semibold))
                if let completedAt = dispatch.completedAt {
                    Text(completedAt, style: .time)
                        .font(AppFont.caption())
                        .foregroundStyle(.appSecondary)
                }
                Spacer()
                if !dispatch.phase.isInFlight, dispatch.phase != .outcomeUncertain {
                    Button("Dismiss") { model.dismissDispatchResult() }
                        .font(AppFont.footnote())
                }
            }

            if dispatch.phase.isInFlight {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(String(localized: dispatch.phase.statusTitle))
                }
                .font(AppFont.footnote())
            } else {
                Label {
                    Text(String(localized: dispatch.phase.statusTitle))
                } icon: {
                    Image(systemName: dispatchStatusIcon(dispatch))
                }
                    .font(AppFont.footnote(weight: .semibold))
                    .foregroundStyle(dispatchStatusColor(dispatch))
            }

            if model.isPreviewStale {
                Label("This Preview is stale. Run Preview Dispatch again before relying on it.", systemImage: "clock.badge.exclamationmark")
                    .font(AppFont.footnote())
                    .foregroundStyle(.orange)
            }

            if let result = dispatch.result {
                dispatchMetrics(result)
            }

            if dispatch.phase == .outcomeUncertain {
                Text("Hermex refreshed the Board, but cannot prove whether workers started. Review the current Board before running Dispatcher again.")
                    .font(AppFont.footnote())
                    .foregroundStyle(.appSecondary)
                if dispatch.canAcknowledgeUncertainOutcome {
                    Button("I Reviewed the Board") {
                        model.dismissDispatchResult()
                    }
                    .font(AppFont.footnote(weight: .semibold))
                    .frame(minHeight: 44)
                }
                Button("Refresh") {
                    Task { await model.refreshUncertainDispatchOutcome() }
                }
                .font(AppFont.footnote(weight: .semibold))
                .frame(minHeight: 44)
            } else if dispatch.phase == .refused {
                Text("The server refused this Dispatcher request. Hermex did not retry it.")
                    .font(AppFont.footnote())
                    .foregroundStyle(.appSecondary)
            } else if dispatch.phase == .boardUnavailable {
                Text("This Board no longer exists. Choose another Board.")
                    .font(AppFont.footnote())
                    .foregroundStyle(.appSecondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            Text(KanbanDispatchAccessibility.summary(dispatch, isStale: model.isPreviewStale))
        )
        .accessibilityFocused($dispatchSummaryIsFocused)
    }

    private func dispatchMetrics(_ result: KanbanDispatchResult) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
            dispatchMetricRow("Spawned", result.spawned, "Promoted", result.promoted)
            dispatchMetricRow("Reclaimed", result.reclaimed, "Skipped—No Assignee", result.skippedUnassigned)
            dispatchMetricRow("Skipped—Unknown Profile", result.skippedNonspawnable, "Auto-blocked", result.autoBlocked)
            dispatchMetricRow("Timed Out", result.timedOut, "Crashed", result.crashed)
        }
        .font(AppFont.caption())
        .accessibilityElement(children: .combine)
    }

    private func dispatchMetricRow(
        _ firstLabel: LocalizedStringKey,
        _ firstCount: Int?,
        _ secondLabel: LocalizedStringKey,
        _ secondCount: Int?
    ) -> some View {
        GridRow {
            dispatchMetric(firstLabel, firstCount)
            dispatchMetric(secondLabel, secondCount)
        }
    }

    private func dispatchMetric(_ label: LocalizedStringKey, _ count: Int?) -> some View {
        HStack(spacing: 4) {
            Text(label)
            Text(count.map(String.init) ?? String(localized: "Unknown"))
                .fontWeight(.semibold)
        }
    }

    private var dispatcherUnavailableReason: LocalizedStringKey? {
        switch model.dispatcherAvailability {
        case .available: nil
        case .busy: "Another Board action is in progress."
        case .outcomeUncertain: "Outcome Uncertain"
        case .offline: "Offline—showing previously loaded data"
        case .incompatible: "Dispatcher is unavailable on this server."
        case .readOnly: "Read-only"
        case .refreshing: "The Board is refreshing."
        case .refreshFailed: "Refresh failed. Try again before using Dispatcher."
        }
    }

    private func dispatchModeTitle(_ mode: KanbanDispatchMode) -> LocalizedStringKey {
        switch mode {
        case .preview: "Preview Dispatch"
        case .run: "Run Dispatcher"
        }
    }

    private func dispatchStatusIcon(_ dispatch: KanbanDispatchState) -> String {
        switch dispatch.phase {
        case .succeeded: model.isPreviewStale ? "clock.badge.exclamationmark" : "checkmark.circle.fill"
        case .submitting, .reconciling: "arrow.triangle.2.circlepath"
        case .refused, .failed: "xmark.circle.fill"
        case .outcomeUncertain, .boardUnavailable: "questionmark.circle.fill"
        }
    }

    private func dispatchStatusColor(_ dispatch: KanbanDispatchState) -> Color {
        switch dispatch.phase {
        case .succeeded: model.isPreviewStale ? .orange : .green
        case .submitting, .reconciling: .secondary
        case .refused, .failed: .red
        case .outcomeUncertain, .boardUnavailable: .orange
        }
    }

    private var boardSelectionContent: some View {
        ContentUnavailableView {
            Label(
                model.boardSelectionNotice?.boardName ?? String(localized: "Board"),
                systemImage: "rectangle.stack.badge.minus"
            )
        } description: {
            Text("This Board no longer exists. Choose another Board.")
        } actions: {
            Menu("Choose Board") {
                ForEach(model.boards, id: \.slug) { board in
                    if let slug = board.slug {
                        Button(board.name ?? slug) {
                            Task { await model.selectBoard(slug) }
                        }
                    }
                }
            }
            .frame(minHeight: 44)
        }
    }

    private var bulkProgressBanner: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(model.bulkActionPhase == .submitting ? "Updating task..." : "Checking Result")
                .font(AppFont.footnote())
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.secondary.opacity(0.1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text(model.bulkActionPhase == .submitting ? "Updating task..." : "Checking Result")
        )
    }

    private func bulkSummaryBanner(_ summary: KanbanBulkActionSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(
                    summary.needsAttention.isEmpty ? "Complete" : "Needs Attention",
                    systemImage: summary.needsAttention.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .font(AppFont.footnote(weight: .semibold))
                Spacer()
                Button("Dismiss") { model.dismissBulkActionSummary() }
                    .font(AppFont.footnote())
            }
            HStack(spacing: 12) {
                Label {
                    HStack(spacing: 3) {
                        Text(verbatim: "\(summary.succeededCount)")
                        Text("Complete")
                    }
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
                Label {
                    HStack(spacing: 3) {
                        Text(verbatim: "\(summary.failedCount)")
                        Text("Failed")
                    }
                } icon: {
                    Image(systemName: "xmark.circle")
                }
                Label {
                    HStack(spacing: 3) {
                        Text(verbatim: "\(summary.uncertainCount)")
                        Text("Outcome Uncertain")
                    }
                } icon: {
                    Image(systemName: "questionmark.circle")
                }
            }
            .font(AppFont.footnote())
            if !summary.needsAttention.isEmpty {
                ForEach(summary.needsAttention) { member in
                    Label {
                        HStack(spacing: 4) {
                            Text(member.cardTitle)
                            Text(member.outcome == .failed ? "Failed" : "Outcome Uncertain")
                        }
                    } icon: {
                        Image(systemName: member.outcome == .failed ? "xmark.circle" : "questionmark.circle")
                    }
                    .font(AppFont.footnote())
                }
            }
            if model.canRetryFailedBulkAction {
                Button("Retry Failed") {
                    Task {
                        await model.retryFailedBulkAction()
                        bulkSummaryIsFocused = true
                    }
                }
                .font(AppFont.footnote(weight: .semibold))
                .frame(minHeight: 44)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(summary.needsAttention.isEmpty ? Color.green.opacity(0.1) : Color.orange.opacity(0.12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(KanbanBulkAccessibility.resultLabel(summary))
        .accessibilityFocused($bulkSummaryIsFocused)
    }

    private var selectionControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(KanbanCountFormatter.cards(model.selectedCardCount))
                    .font(AppFont.subheadline(weight: .semibold))
                    .accessibilityLabel(
                        Text(KanbanCountFormatter.cards(model.selectedCardCount))
                        + Text(", ")
                        + Text("Selected")
                    )
                Spacer()
                Button("Bulk Actions") { showsBulkActions = true }
                    .disabled(model.bulkActionsAvailability != .available)
                    .fontWeight(.semibold)
                    .frame(minHeight: 44)
                Button("Done") {
                    model.clearCardSelection()
                }
                .frame(minHeight: 44)
            }
            if let explanation = bulkDisabledExplanation {
                Text(explanation)
                    .font(AppFont.footnote())
                    .foregroundStyle(.appSecondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.secondary.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityFocused($selectionControlsAreFocused)
    }

    private var bulkDisabledExplanation: String? {
        switch model.bulkActionsAvailability {
        case .available: nil
        case .noSelection: nil
        case .offline: String(localized: "Offline—showing previously loaded data")
        case .incompatible: String(localized: "Unavailable")
        case .readOnly: String(localized: "Read-only")
        case .refreshing: String(localized: "The Board is refreshing.")
        case .boardBusy: String(localized: "Updating task...")
        case .invalidSelection: String(localized: "The selection is no longer available. Refresh the Board and select the Cards again.")
        case .unknownStatus: String(localized: "Unknown Status")
        }
    }

    private func archiveUndoBanner(_ undo: KanbanArchiveUndo) -> some View {
        let recovery = model.mutationState(for: undo.cardID)
        let recoveryPhase = recovery?.phase
        let statusText = recoveryPhase == .outcomeUncertain
            ? String(localized: "Outcome Uncertain")
            : recoveryPhase == .failed
                ? String(localized: "Update failed")
                : String(localized: "Archived")
        let hasRecoveryError = recoveryPhase == .outcomeUncertain || recoveryPhase == .failed
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Label(
                    statusText,
                    systemImage: hasRecoveryError ? "exclamationmark.circle" : "archivebox"
                )
                    .lineLimit(2)
                if recoveryPhase == .failed, let message = recovery?.message {
                    Text(verbatim: message)
                        .foregroundStyle(.appSecondary)
                }
            }
            Spacer()
            if recoveryPhase == .outcomeUncertain {
                Button("Refresh") {
                    Task { await model.checkUncertainMutation(for: undo.card) }
                }
                .fontWeight(.semibold)
            } else {
                Button(recoveryPhase == .failed ? "Try Again" : "Undo") {
                    Task { await model.undoArchive() }
                }
                .fontWeight(.semibold)
            }
        }
        .font(AppFont.footnote())
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.secondary.opacity(0.1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            Text(
                String.localizedStringWithFormat(
                    String(localized: "%@, %@"),
                    undo.cardTitle,
                    statusText
                )
            )
        )
        .accessibilityFocused($archiveUndoIsFocused)
    }

    /// The server's note on the Card just created, such as a Hermes host's warning that no
    /// dispatcher is running to pick it up (#1044).
    private func cardNoticeBanner(_ notice: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label {
                Text(verbatim: notice)
            } icon: {
                Image(systemName: "info.circle")
            }
            Spacer()
            Button {
                model.dismissCardNotice()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .accessibilityLabel(Text("Dismiss"))
            .frame(minWidth: 44, minHeight: 44)
        }
        .font(AppFont.footnote())
        .foregroundStyle(.appSecondary)
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(.secondary.opacity(0.08))
        .accessibilityElement(children: .contain)
    }

    private var offlineBanner: some View {
        Label("Offline—showing previously loaded data", systemImage: "wifi.slash")
            .font(AppFont.footnote())
            .foregroundStyle(.orange)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12))
            .accessibilityLabel(Text("Offline—showing previously loaded data"))
    }

    private var liveUpdatesDelayedBanner: some View {
        Label("Live updates delayed", systemImage: "arrow.clockwise.circle")
            .font(AppFont.footnote())
            .foregroundStyle(.appSecondary)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.secondary.opacity(0.08))
            .accessibilityLabel(Text("Live updates delayed"))
    }

    private var compatibilityBanner: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Kanban is available with limited capabilities.")
                if !model.unavailableWriteCapabilities.isEmpty {
                    Text("Unavailable")
                        + Text(verbatim: ": ")
                        + Text(verbatim: unavailableWriteCapabilityNames)
                }
            }
            .font(AppFont.footnote())
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.orange)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12))
    }

    private var unavailableWriteCapabilityNames: String {
        KanbanWriteCapability.allCases
            .filter(model.unavailableWriteCapabilities.contains)
            .map(\.title)
            .joined(separator: ", ")
    }

    private var refreshErrorBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label("Could not refresh this Board. Previously loaded Cards remain visible.", systemImage: "exclamationmark.triangle")
                .font(AppFont.footnote())
            Spacer(minLength: 4)
            Button("Try Again") { Task { await model.refresh() } }
                .font(AppFont.footnote(weight: .semibold))
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.red.opacity(0.1))
    }

    private var statusSelector: some View {
        KanbanStatusSelector(model: model)
    }

    private struct KanbanStatusSelector: UIViewRepresentable {
        @Bindable var model: KanbanFeatureState
        @ScaledMetric(relativeTo: .subheadline) private var height: CGFloat = 56

        func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }

        func makeUIView(context: Context) -> UIScrollView {
            let scrollView = KanbanStatusScrollView()
            scrollView.alwaysBounceHorizontal = false
            scrollView.alwaysBounceVertical = false
            scrollView.delaysContentTouches = false
            scrollView.isDirectionalLockEnabled = true
            scrollView.showsHorizontalScrollIndicator = false
            scrollView.showsVerticalScrollIndicator = false
            scrollView.refreshControl = nil
            scrollView.accessibilityIdentifier = "KanbanStatusSelector"
            context.coordinator.install(in: scrollView)
            return scrollView
        }

        func updateUIView(_ scrollView: UIScrollView, context: Context) {
            context.coordinator.parent = self
            context.coordinator.update(height: height, dynamicTypeSize: context.environment.dynamicTypeSize)
        }

        @MainActor
        final class KanbanStatusScrollView: UIScrollView {
            override func touchesShouldCancel(in view: UIView) -> Bool {
                true
            }
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            uiView: UIScrollView,
            context: Context
        ) -> CGSize? {
            CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width, height: height)
        }

        @MainActor
        final class Coordinator: NSObject {
            var parent: KanbanStatusSelector
            private let stackView = UIStackView()
            private var controls: [String: KanbanStatusControl] = [:]
            private var orderedStatuses: [String] = []

            init(parent: KanbanStatusSelector) {
                self.parent = parent
            }

            func install(in scrollView: UIScrollView) {
                stackView.axis = .horizontal
                stackView.alignment = .center
                stackView.spacing = 8
                stackView.translatesAutoresizingMaskIntoConstraints = false
                scrollView.addSubview(stackView)
                let tapRecognizer = UITapGestureRecognizer(
                    target: self,
                    action: #selector(selectStatus(at:))
                )
                tapRecognizer.cancelsTouchesInView = false
                scrollView.addGestureRecognizer(tapRecognizer)

                NSLayoutConstraint.activate([
                    stackView.leadingAnchor.constraint(
                        equalTo: scrollView.contentLayoutGuide.leadingAnchor,
                        constant: 16
                    ),
                    stackView.trailingAnchor.constraint(
                        equalTo: scrollView.contentLayoutGuide.trailingAnchor,
                        constant: -16
                    ),
                    stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
                    stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
                    stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
                ])
            }

            func update(height: CGFloat, dynamicTypeSize: DynamicTypeSize) {
                let statuses = parent.model.availableStatuses
                if statuses != orderedStatuses {
                    rebuild(statuses)
                }

                let controlHeight = max(44, height - 12)
                for status in statuses {
                    let presentation = KanbanStatusPresentation(status)
                    controls[status]?.update(
                        title: presentation.title,
                        count: parent.model.statusCount(status),
                        color: UIColor(presentation.color),
                        isSelected: parent.model.selectedStatus == status,
                        height: controlHeight,
                        dynamicTypeSize: dynamicTypeSize
                    )
                }
            }

            private func rebuild(_ statuses: [String]) {
                orderedStatuses = statuses
                for view in stackView.arrangedSubviews {
                    stackView.removeArrangedSubview(view)
                    view.removeFromSuperview()
                }
                controls.removeAll()

                for status in statuses {
                    let control = KanbanStatusControl()
                    control.status = status
                    control.addTarget(
                        self,
                        action: #selector(selectStatus(_:)),
                        for: [.touchUpInside, .primaryActionTriggered]
                    )
                    stackView.addArrangedSubview(control)
                    controls[status] = control
                }
            }

            @objc
            private func selectStatus(_ sender: KanbanStatusControl) {
                parent.model.selectedStatus = sender.status
            }

            @objc
            private func selectStatus(at recognizer: UITapGestureRecognizer) {
                guard recognizer.state == .ended else { return }
                let location = recognizer.location(in: stackView)
                guard let control = stackView.arrangedSubviews
                    .compactMap({ $0 as? KanbanStatusControl })
                    .first(where: { $0.frame.contains(location) })
                else { return }
                parent.model.selectedStatus = control.status
            }
        }

        @MainActor
        final class KanbanStatusControl: UIControl {
            var status = ""
            private let dotView = UIView()
            private let titleLabel = UILabel()
            private let countLabel = UILabel()
            private let stackView = UIStackView()
            private var heightConstraint: NSLayoutConstraint?

            override init(frame: CGRect) {
                super.init(frame: frame)
                isAccessibilityElement = true
                layer.cornerCurve = .continuous

                dotView.translatesAutoresizingMaskIntoConstraints = false
                dotView.layer.cornerRadius = 4
                NSLayoutConstraint.activate([
                    dotView.widthAnchor.constraint(equalToConstant: 8),
                    dotView.heightAnchor.constraint(equalToConstant: 8)
                ])

                titleLabel.adjustsFontForContentSizeCategory = true
                titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
                countLabel.adjustsFontForContentSizeCategory = true
                countLabel.font = .monospacedDigitSystemFont(
                    ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
                    weight: .regular
                )
                countLabel.textColor = .appTextSecondary

                stackView.axis = .horizontal
                stackView.alignment = .center
                stackView.spacing = 6
                stackView.translatesAutoresizingMaskIntoConstraints = false
                stackView.addArrangedSubview(dotView)
                stackView.addArrangedSubview(titleLabel)
                stackView.addArrangedSubview(countLabel)
                addSubview(stackView)

                NSLayoutConstraint.activate([
                    stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                    stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                    stackView.centerYAnchor.constraint(equalTo: centerYAnchor)
                ])
            }

            @available(*, unavailable)
            required init?(coder: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }

            func update(
                title: String,
                count: Int,
                color: UIColor,
                isSelected: Bool,
                height: CGFloat,
                dynamicTypeSize: DynamicTypeSize
            ) {
                titleLabel.text = title
                let preferredTitleFont = UIFont.preferredFont(forTextStyle: .subheadline, at: dynamicTypeSize)
                titleLabel.font = .app(
                    size: preferredTitleFont.pointSize,
                    weight: isSelected ? .semibold : .regular
                )
                countLabel.font = .monospacedDigitSystemFont(
                    ofSize: UIFont.preferredFont(forTextStyle: .caption1, at: dynamicTypeSize).pointSize,
                    weight: .regular
                )
                countLabel.text = "\(count)"
                dotView.backgroundColor = color
                self.isSelected = isSelected
                backgroundColor = isSelected ? .secondarySystemFill : .clear
                layer.cornerRadius = height / 2
                accessibilityLabel = String.localizedStringWithFormat(
                    String(localized: "%@, %@"),
                    title,
                    KanbanCountFormatter.cards(count)
                )
                accessibilityTraits = isSelected ? [.button, .selected] : .button

                if heightConstraint?.constant != height {
                    heightConstraint?.isActive = false
                    heightConstraint = heightAnchor.constraint(equalToConstant: height)
                    heightConstraint?.isActive = true
                }
            }
        }
    }

    private var cardList: some View {
        AppList(rows: .plain) {
            if model.showsBoardLoadingRow {
                HStack {
                    Spacer()
                    ProgressView("Refreshing Board")
                    Spacer()
                }
                .listRowSeparator(.hidden)
            }

            if model.isRefreshing, model.snapshot == nil {
                EmptyView()
            } else if model.visibleCards.isEmpty {
                emptyContent
                    .listRowSeparator(.hidden)
            } else if model.groupByProfile {
                ForEach(model.groupedVisibleCards, id: \.profile) { group in
                    Section {
                        ForEach(group.cards, id: \.cardID) { card in
                            cardNavigationLink(card)
                        }
                    } header: {
                        Text(group.profile ?? String(localized: "Unassigned"))
                    }
                }
            } else {
                ForEach(model.visibleCards, id: \.cardID) { card in
                    cardNavigationLink(card)
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await model.refresh() }
    }

    @ViewBuilder
    private func cardNavigationLink(_ card: KanbanCard) -> some View {
        if model.isSelectingCards {
            Button {
                activateCard(card)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: model.selectedCardIDs.contains(card.cardID ?? "")
                          ? "checkmark.circle.fill"
                          : "circle")
                        .font(AppFont.title3())
                    KanbanCardSummaryView(card: card)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .accessibilityLabel(
                KanbanBulkAccessibility.selectionLabel(
                    card,
                    isSelected: model.selectedCardIDs.contains(card.cardID ?? "")
                )
            )
            .accessibilityAddTraits(
                model.selectedCardIDs.contains(card.cardID ?? "")
                    ? .isSelected
                    : AccessibilityTraits()
            )
        } else {
            ZStack(alignment: .trailing) {
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        activateCard(card)
                    } label: {
                        KanbanCardSummaryView(card: card, reservesTrailingActionSpace: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .disabled(card.cardID == nil)
                    .accessibilityLabel(KanbanCardAccessibility.summary(card))
                    .accessibilityFocused($focusedCardID, equals: card.cardID)

                    mutationStatus(for: card)
                }

                cardActionsMenu(card)
            }
        }
    }

    private func activateCard(_ card: KanbanCard) {
        switch KanbanCardRowPrimaryAction.resolve(for: card, isSelecting: model.isSelectingCards) {
        case let .openDetail(cardID):
            focusedCardID = cardID
            presentedCardID = cardID
        case .toggleSelection:
            model.toggleCardSelection(card)
            selectionControlsAreFocused = true
        case nil:
            break
        }
    }

    private func cardActionsMenu(_ card: KanbanCard) -> some View {
        Menu {
            let destinations = model.moveDestinations(for: card)
            if !destinations.isEmpty {
                Menu("Move") {
                    ForEach(destinations, id: \.self) { destination in
                        Button(KanbanStatusPresentation(destination).title) {
                            request(.move(destination), for: card)
                        }
                    }
                }
            }
            if card.status?.rawValue == "blocked" {
                Button("Unblock") { request(.unblock, for: card) }
            } else if model.canBlock(card) {
                Button("Block") { request(.block, for: card) }
            }
            if model.canComplete(card) {
                Button("Complete") { request(.complete(result: nil), for: card) }
            }
            if card.status?.rawValue != "archived" {
                Button("Archive", role: .destructive) { request(.archive, for: card) }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.appPrimary)
                .frame(minWidth: 44, minHeight: 44)
        }
        .tint(.primary)
        .disabled(!model.canMutateCard(card) || model.isMutatingCard(card.cardID))
        .accessibilityLabel(Text("Card Actions"))
    }

    @ViewBuilder
    private func mutationStatus(for card: KanbanCard) -> some View {
        if let mutation = model.mutationState(for: card.cardID) {
            switch mutation.phase {
            case .updating:
                Label("Updating task...", systemImage: "arrow.triangle.2.circlepath")
                    .font(AppFont.footnote()).foregroundStyle(.appSecondary)
            case .checkingResult:
                Label("Checking Result", systemImage: "arrow.triangle.2.circlepath")
                    .font(AppFont.footnote()).foregroundStyle(.appSecondary)
            case .succeeded:
                Label("Updated", systemImage: "checkmark.circle.fill")
                    .font(AppFont.footnote()).foregroundStyle(.green)
            case .failed:
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Label("Update failed", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                        Button("Try Again") { retryMutation(for: card) }
                    }
                    if let message = mutation.message {
                        Text(verbatim: message)
                            .foregroundStyle(.appSecondary)
                    }
                }
                .font(AppFont.footnote())
            case .outcomeUncertain:
                HStack {
                    Label("Outcome Uncertain", systemImage: "questionmark.circle")
                        .foregroundStyle(.orange)
                    Button("Refresh") { Task { await model.checkUncertainMutation(for: card) } }
                }
                .font(AppFont.footnote())
            }
        }
    }

    private func request(_ action: KanbanCardAction, for card: KanbanCard) {
        if action == .complete(result: nil), model.completionNeedsResult(card) {
            pendingCompletion = card
        } else if card.status?.rawValue == "running" {
            pendingRunningAction = KanbanPendingCardAction(card: card, action: action)
        } else {
            perform(action, for: card)
        }
    }

    private func perform(
        _ action: KanbanCardAction,
        for card: KanbanCard,
        confirmingRunningExit: Bool = false
    ) {
        Task {
            switch action {
            // A Hermes host can land a Card elsewhere than asked (#1044), so the list follows it.
            case let .move(status):
                await model.moveCard(card, to: status, confirmingRunningExit: confirmingRunningExit)
                if model.mutationState(for: card.cardID)?.phase == .succeeded {
                    model.selectedStatus = model.status(ofCard: card.cardID) ?? status
                    await Task.yield()
                    focusedCardID = card.cardID
                }
            case .block:
                await model.blockCard(card, reason: nil, confirmingRunningExit: confirmingRunningExit)
                if model.mutationState(for: card.cardID)?.phase == .succeeded {
                    model.selectedStatus = model.status(ofCard: card.cardID) ?? "blocked"
                    await Task.yield()
                    focusedCardID = card.cardID
                }
            case .unblock:
                await model.unblockCard(card)
                if model.mutationState(for: card.cardID)?.phase == .succeeded {
                    model.selectedStatus = model.status(ofCard: card.cardID) ?? "ready"
                    await Task.yield()
                    focusedCardID = card.cardID
                }
            case let .complete(result):
                await model.completeCard(card, result: result, confirmingRunningExit: confirmingRunningExit)
                if model.mutationState(for: card.cardID)?.phase == .succeeded {
                    model.selectedStatus = "done"
                    await Task.yield()
                    focusedCardID = card.cardID
                }
            case .archive:
                await model.archiveCard(card, confirmingRunningExit: confirmingRunningExit)
                if model.hasAvailableArchiveUndo {
                    archiveUndoIsFocused = true
                }
            }
        }
    }

    private func retryMutation(for card: KanbanCard) {
        guard card.status?.rawValue == "running",
              let mutation = model.mutationState(for: card.cardID) else {
            Task { await model.retryMutation(for: card) }
            return
        }
        switch mutation.kind {
        case let .status(status): request(.move(status), for: card)
        case let .complete(result): request(.complete(result: result), for: card)
        case .block: request(.block, for: card)
        case .archive: request(.archive, for: card)
        default: Task { await model.retryMutation(for: card) }
        }
    }

    private var emptyContent: some View {
        ContentUnavailableView {
            Label(
                model.hasActiveFilters ? String(localized: "No matching Cards") : String(localized: "No Cards in this Status"),
                systemImage: model.hasActiveFilters ? "line.3.horizontal.decrease.circle" : "rectangle.stack"
            )
        } description: {
            Text(model.hasActiveFilters
                 ? String(localized: "Change or clear the filters to see more Cards.")
                 : String(localized: "Choose another Status or refresh the Board."))
        } actions: {
            if model.hasActiveFilters {
                Button("Clear Filters") { Task { await model.clearFilters() } }
                    .frame(minHeight: 44)
            }
        }
    }

    private var boardTitle: String {
        model.selectedBoard?.name ?? model.selectedBoardSlug ?? String(localized: "Board")
    }

    private var boardPickerMaxWidth: CGFloat {
        KanbanHeaderPresentation.boardPickerMaxWidth(
            barWidth: barWidth,
            trailingGroupWidth: trailingGroupWidth
        )
    }

    /// The navigation bar drops the `.principal` slot outright when its content insists
    /// on a width that will not fit beside the bar's other items — the original #340
    /// bug, where a long Board name took the picker off screen entirely. A custom
    /// principal item is not constrained by its siblings on iOS 26 either: given
    /// `.frame(maxWidth: .infinity)` it spans the whole bar and draws under the back
    /// button and the trailing controls. Handing the title to the system instead
    /// (`.navigationTitle` + `.toolbarTitleMenu`) trades one bug for another: UIKit
    /// makes room for the full title by collapsing New Card and Dispatcher into a
    /// system overflow button, hiding the Dispatcher's state icon. So the picker keeps
    /// its own slot and an explicit width cap that can never exceed the real gap, and
    /// truncates inside it.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Menu {
                ForEach(model.boards, id: \.slug) { board in
                    if let slug = board.slug {
                        Button {
                            Task { await model.selectBoard(slug) }
                        } label: {
                            if slug == model.selectedBoardSlug {
                                Label(board.name ?? slug, systemImage: "checkmark")
                            } else {
                                Text(board.name ?? slug)
                            }
                        }
                    }
                }
                Divider()
                Button {
                    showsBoardManagement = true
                } label: {
                    Label("Manage", systemImage: "slider.horizontal.3")
                }
            } label: {
                HStack(spacing: 4) {
                    Text(boardTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(AppFont.caption2())
                        .layoutPriority(1)
                }
                .frame(maxWidth: boardPickerMaxWidth, minHeight: 44)
            }
            .accessibilityLabel(String(localized: "Switch Board"))
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                cardEditor = model.makeCreateCardEditorState()
            } label: {
                Image(systemName: "plus")
            }
            .disabled(!model.canCreateCards)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(Text("New Card"))

            Button {
                showsDispatcher = true
            } label: {
                Label(
                    "Dispatcher",
                    systemImage: KanbanDispatcherPresentation.toolbarSystemImage(
                        for: model.dispatchState
                    )
                )
            }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(
                Text(KanbanDispatcherPresentation.toolbarAccessibilityLabel(for: model.dispatchState))
            )
            .accessibilityFocused($dispatcherButtonIsFocused)

            // Select Cards and Card Filters sit behind More so the trailing group stays
            // narrow enough to leave the inline Board title room to read. Select mode
            // swaps More for Cancel in the same slot.
            if model.isSelectingCards {
                Button {
                    model.clearCardSelection()
                } label: {
                    Image(systemName: "xmark")
                }
                .disabled(model.bulkActionPhase != nil || !model.canUseBulkActions)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel(Text("Cancel"))
            } else {
                Menu {
                    Button {
                        model.beginSelectingCards()
                        selectionControlsAreFocused = true
                    } label: {
                        Label("Select Cards", systemImage: "checkmark.circle")
                    }
                    .disabled(model.bulkActionPhase != nil || !model.canUseBulkActions)

                    Button {
                        showsFilters = true
                    } label: {
                        Label(
                            "Card Filters",
                            systemImage: KanbanHeaderPresentation.cardFiltersSystemImage(
                                hasActiveFilters: model.hasActiveFilters
                            )
                        )
                    }
                } label: {
                    Image(
                        systemName: KanbanHeaderPresentation.overflowSystemImage(
                            hasActiveFilters: model.hasActiveFilters
                        )
                    )
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel(Text("More"))
            }
        }
    }

    private func unavailableContent(title: String, detail: String, systemImage: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(detail)
        } actions: {
            Button("Try Again") { Task { await model.retry() } }
                .frame(minHeight: 44)
        }
    }
}

private enum KanbanBoardEditorMode: Identifiable {
    case create
    case edit(KanbanBoard)

    var id: String {
        switch self {
        case .create: "create"
        case let .edit(board): "edit-\(board.slug ?? "")"
        }
    }
}

private struct KanbanBoardStatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
        .accessibilityElement(children: .combine)
    }
}

private struct KanbanBoardManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: KanbanFeatureState
    @State private var editorMode: KanbanBoardEditorMode?
    @State private var pendingArchive: KanbanBoard?
    @State private var pendingActivation: KanbanBoard?

    var body: some View {
        AppList {
            if let mutation = model.boardMutationState {
                Section {
                    boardMutationStatus(mutation)
                }
            }

            Section {
                ForEach(model.boards, id: \.slug) { board in
                    boardRow(board)
                }
            } appFooter: {
                Text("Browsing a Board stays local to Hermex. Making a Board active changes shared server state.")
            }
        }
        .themedPageBackground()
        .navigationTitle("Manage")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.dismissBoardMutationResult()
                    editorMode = .create
                } label: {
                    Label("Create", systemImage: "plus")
                }
                .disabled(!model.canManageBoards)
                .accessibilityHint(Text("Creating a Board does not make it active."))
            }
        }
        .sheet(item: $editorMode) { mode in
            NavigationStack {
                KanbanBoardEditorView(model: model, mode: mode)
            }
        }
        .alert(
            "Archive",
            isPresented: Binding(
                get: { pendingArchive != nil },
                set: { if !$0 { pendingArchive = nil } }
            ),
            presenting: pendingArchive
        ) { board in
            Button("Cancel", role: .cancel) { pendingArchive = nil }
            Button("Archive", role: .destructive) {
                pendingArchive = nil
                Task { await model.archiveBoard(slug: board.slug ?? "") }
            }
        } message: { _ in
            Text("Hermex cannot restore an archived Board in-app.")
        }
        .alert(
            "Make Active Board",
            isPresented: Binding(
                get: { pendingActivation != nil },
                set: { if !$0 { pendingActivation = nil } }
            ),
            presenting: pendingActivation
        ) { board in
            Button("Cancel", role: .cancel) { pendingActivation = nil }
            Button("Make Active Board") {
                pendingActivation = nil
                Task { await model.makeBoardActive(slug: board.slug ?? "") }
            }
        } message: { _ in
            Text("Making this Board active changes shared server state for other Hermes clients.")
        }
    }

    private func boardRow(_ board: KanbanBoard) -> some View {
        let presentation = KanbanBoardRowPresentation(
            board: board,
            selectedBoardSlug: model.selectedBoardSlug,
            sharedActiveBoardSlug: model.sharedActiveBoardSlug,
            canManageBoards: model.canManageBoards
        )

        return HStack(alignment: .top, spacing: 8) {
            boardBrowseControl(board, presentation: presentation)
            boardActionsMenu(board, presentation: presentation)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func boardBrowseControl(
        _ board: KanbanBoard,
        presentation: KanbanBoardRowPresentation
    ) -> some View {
        if let slug = presentation.browseSlug {
            Button {
                Task { await model.selectBoard(slug) }
            } label: {
                boardRowContent(board, presentation: presentation)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                Text(
                    KanbanBoardAccessibility.browseSummary(
                        board,
                        isActive: presentation.isActive
                    )
                )
            )
            .accessibilityHint(
                Text("Browsing a Board stays local to Hermex. Making a Board active changes shared server state.")
            )
        } else {
            boardRowContent(board, presentation: presentation)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(
                    presentation.isBrowsing ? .isSelected : AccessibilityTraits()
                )
        }
    }

    private func boardRowContent(
        _ board: KanbanBoard,
        presentation: KanbanBoardRowPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(board.icon ?? "▣")
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(board.name ?? board.slug ?? String(localized: "Board"))
                        .font(AppFont.headline())
                    if let slug = board.slug {
                        Text(slug)
                            .font(.caption.monospaced())
                            .foregroundStyle(.appSecondary)
                    }
                }
            }

            if presentation.isBrowsing || presentation.isActive {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        boardStatusIndicators(presentation)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        boardStatusIndicators(presentation)
                    }
                }
                .font(AppFont.caption())
                .foregroundStyle(.appSecondary)
                .labelStyle(KanbanBoardStatusLabelStyle())
            }

            if let description = board.description, !description.isEmpty {
                Text(description)
                    .font(AppFont.subheadline())
                    .foregroundStyle(.appSecondary)
            }
            Text(KanbanCountFormatter.cards(board.total ?? 0))
                .font(AppFont.caption())
                .foregroundStyle(.appSecondary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func boardStatusIndicators(_ presentation: KanbanBoardRowPresentation) -> some View {
        if presentation.isBrowsing {
            Label("Browsing", systemImage: "eye.fill")
        }
        if presentation.isActive {
            Label("Active", systemImage: "checkmark.circle.fill")
        }
    }

    private func boardActionsMenu(
        _ board: KanbanBoard,
        presentation: KanbanBoardRowPresentation
    ) -> some View {
        Menu {
            if presentation.actions.contains(.edit) {
                Button {
                    model.dismissBoardMutationResult()
                    editorMode = .edit(board)
                } label: {
                    Label("Edit", systemImage: KanbanBoardRowAction.edit.systemImage)
                }
            }
            if presentation.actions.contains(.makeActive) {
                Button {
                    pendingActivation = board
                } label: {
                    Label(
                        "Make Active Board",
                        systemImage: KanbanBoardRowAction.makeActive.systemImage
                    )
                }
            }
            if presentation.actions.contains(.archive) {
                Button(role: .destructive) {
                    pendingArchive = board
                } label: {
                    Label("Archive", systemImage: KanbanBoardRowAction.archive.systemImage)
                }
            }
        } label: {
            Label(
                KanbanBoardAccessibility.actionsLabel(board),
                systemImage: "ellipsis.circle"
            )
            .labelStyle(.iconOnly)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!presentation.mutationsAreEnabled || presentation.actions.isEmpty)
        .accessibilityLabel(Text(KanbanBoardAccessibility.actionsLabel(board)))
        .accessibilityHint(Text("Shows available Board management actions."))
    }

    private func boardMutationStatus(_ mutation: KanbanBoardMutationState) -> some View {
        HStack(spacing: 10) {
            if mutation.phase.isInFlight {
                ProgressView()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(boardMutationAction(mutation.kind))
                    .font(AppFont.headline())
                Text(boardMutationPhase(mutation.phase))
                    .foregroundStyle(.appSecondary)
                if let message = mutation.message {
                    Text(verbatim: message)
                        .font(AppFont.footnote())
                        .foregroundStyle(.appSecondary)
                }
            }
            Spacer()
            if mutation.phase == .outcomeUncertain {
                Button("Check Result") {
                    Task { await model.checkBoardMutationResult() }
                }
            } else if !mutation.phase.isInFlight {
                Button {
                    model.dismissBoardMutationResult()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .accessibilityLabel(Text("Dismiss"))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func boardMutationAction(_ kind: KanbanBoardMutationKind) -> LocalizedStringKey {
        switch kind {
        case .create: "Create"
        case .edit: "Edit"
        case .archive: "Archive"
        case .makeActive: "Make Active Board"
        }
    }

    private func boardMutationPhase(_ phase: KanbanCardMutationPhase) -> LocalizedStringKey {
        switch phase {
        case .updating: "Updating Board..."
        case .checkingResult: "Checking Result"
        case .succeeded: "Done"
        case .failed: "Failed"
        case .outcomeUncertain: "Outcome Uncertain"
        }
    }
}

private struct KanbanBoardEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: KanbanFeatureState
    let mode: KanbanBoardEditorMode
    @State private var slug: String
    @State private var name: String
    @State private var description: String
    @State private var icon: String
    @State private var color: String
    @State private var showsSlugError = false
    @State private var showsNameError = false

    init(model: KanbanFeatureState, mode: KanbanBoardEditorMode) {
        self.model = model
        self.mode = mode
        switch mode {
        case .create:
            _slug = State(initialValue: "")
            _name = State(initialValue: "")
            _description = State(initialValue: "")
            _icon = State(initialValue: "")
            _color = State(initialValue: "")
        case let .edit(board):
            _slug = State(initialValue: board.slug ?? "")
            _name = State(initialValue: board.name ?? "")
            _description = State(initialValue: board.description ?? "")
            _icon = State(initialValue: board.icon ?? "")
            _color = State(initialValue: board.color ?? "")
        }
    }

    var body: some View {
        AppForm {
            Section {
                TextField("Slug", text: $slug)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(isEditing)
                    .accessibilityHint(Text("The slug cannot be changed after the Board is created."))
                if showsSlugError {
                    Text("Required")
                        .font(AppFont.caption())
                        .foregroundStyle(.red)
                }
                TextField("Name", text: $name)
                if showsNameError {
                    Text("Required")
                        .font(AppFont.caption())
                        .foregroundStyle(.red)
                }
                TextField("Description", text: $description, axis: .vertical)
                    .lineLimit(2...5)
                TextField("Icon", text: $icon)
                TextField("Color", text: $color)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } appFooter: {
                Text("Creating a Board does not make it active.")
            }

            if let mutation = model.boardMutationState,
               mutation.kind.slug == slug,
               mutation.phase == .failed || mutation.phase == .outcomeUncertain {
                Section {
                    Text(mutation.phase == .failed ? "Failed" : "Outcome Uncertain")
                        .foregroundStyle(.red)
                    if let message = mutation.message {
                        Text(verbatim: message)
                            .font(AppFont.footnote())
                    }
                    Text("Refresh the Board before trying again.")
                        .font(AppFont.footnote())
                }
            }
        }
        .themedPageBackground()
        .navigationTitle(isEditing ? "Edit" : "Create")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { submit() }
                    .disabled(!model.canManageBoards)
            }
        }
    }

    private var isEditing: Bool {
        if case .edit = mode { true } else { false }
    }

    private func submit() {
        let trimmedSlug = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        showsSlugError = trimmedSlug.isEmpty
        showsNameError = trimmedName.isEmpty
        guard !showsSlugError, !showsNameError else { return }
        Task {
            if isEditing {
                await model.editBoard(KanbanEditBoardRequest(
                    slug: trimmedSlug,
                    name: trimmedName,
                    description: description,
                    icon: icon,
                    color: color
                ))
            } else {
                await model.createBoard(KanbanCreateBoardRequest(
                    slug: trimmedSlug,
                    name: trimmedName,
                    description: description,
                    icon: icon,
                    color: color
                ))
            }
            if model.boardMutationState?.phase == .succeeded {
                dismiss()
            }
        }
    }
}

private struct KanbanBulkActionsView: View {
    @Environment(\.dismiss) private var dismiss
    let model: KanbanFeatureState
    let onArchive: () -> Void
    let onFinished: () -> Void
    @State private var status: String
    /// What was done, for Done on Cards a Hermes host completes only with a note (#1677).
    @State private var result = ""
    @State private var profile: String?
    @State private var priority = 0

    init(model: KanbanFeatureState, onArchive: @escaping () -> Void, onFinished: @escaping () -> Void) {
        self.model = model
        self.onArchive = onArchive
        self.onFinished = onFinished
        // To Do, as before, where it is offered; a Hermes host offers no To Do (#1044).
        let options = model.bulkStatusOptions
        _status = State(initialValue: options.contains("todo") ? "todo" : options.first ?? "triage")
    }

    var body: some View {
        NavigationStack {
            AppForm {
                Section {
                    Text(KanbanCountFormatter.cards(model.selectedCardCount))
                        .font(AppFont.headline())
                }

                Section("Change Status") {
                    Picker("Status", selection: $status) {
                        ForEach(statusOptions, id: \.self) { value in
                            Text(KanbanStatusPresentation(value).title).tag(value)
                        }
                    }
                    if case .complete = statusAction {
                        TextField("What was done?", text: $result, axis: .vertical)
                    }
                    Button("Change Status") {
                        submit(statusAction)
                    }
                    .disabled(!model.canSubmitBulkAction(statusAction))
                    .frame(minHeight: 44)
                }

                Section("Assign Profile") {
                    Picker("Profile", selection: $profile) {
                        Text("Unassigned").tag(String?.none)
                        ForEach(model.profileOptions, id: \.self) { value in
                            Text(value).tag(Optional(value))
                        }
                    }
                    Button("Assign Profile") {
                        submit(.assignProfile(profile))
                    }
                    .disabled(!model.canSubmitBulkAction(.assignProfile(profile)))
                    .frame(minHeight: 44)
                }

                Section("Set Priority") {
                    Stepper(value: $priority, in: -100...100) {
                        HStack {
                            Text("Priority")
                            Text(verbatim: "\(priority)")
                        }
                    }
                    Button("Set Priority") {
                        submit(.setPriority(priority))
                    }
                    .disabled(!model.canSubmitBulkAction(.setPriority(priority)))
                    .frame(minHeight: 44)
                }

                Section {
                    Button("Archive Cards", role: .destructive) {
                        onArchive()
                    }
                    .disabled(!model.canSubmitBulkAction(.archiveCards))
                    .frame(minHeight: 44)
                }
            }
            .themedPageBackground()
            .navigationTitle("Bulk Actions")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(model.bulkActionPhase != nil)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(model.bulkActionPhase != nil)
                }
            }
        }
    }

    private var statusOptions: [String] {
        model.bulkStatusOptions
    }

    private var statusAction: KanbanBulkAction {
        model.bulkStatusAction(status, result: result.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func submit(_ action: KanbanBulkAction) {
        Task {
            await model.performBulkAction(action)
            onFinished()
        }
    }
}

private struct KanbanFiltersView: View {
    @Environment(\.dismiss) private var dismiss
    let model: KanbanFeatureState
    @State private var draft: KanbanFiltersDraft

    init(model: KanbanFeatureState) {
        self.model = model
        _draft = State(initialValue: KanbanFiltersDraft(model: model))
    }

    var body: some View {
        NavigationStack {
            AppForm {
                Section("Profile") {
                    Picker("Assigned Profile", selection: $draft.profile) {
                        Text("All Profiles").tag(String?.none)
                        ForEach(model.profileOptions, id: \.self) { value in
                            Text(value).tag(Optional(value))
                        }
                    }
                    .disabled(draft.onlyMine)
                    if model.offersOnlyMine {
                        Toggle("Only Mine", isOn: $draft.onlyMine)
                            .onChange(of: draft.onlyMine) { _, enabled in
                                if enabled { draft.profile = nil }
                            }
                    }
                }

                Section("Tenant") {
                    Picker("Tenant", selection: $draft.tenant) {
                        Text("All Tenants").tag(String?.none)
                        ForEach(model.tenantOptions, id: \.self) { value in
                            Text(value).tag(Optional(value))
                        }
                    }
                }

                Section("Archived Cards") {
                    Toggle("Include Archived Cards", isOn: $draft.includesArchived)
                }

                Section("Display") {
                    Toggle("Group by Profile", isOn: $draft.groupsByProfile)
                }

                if model.hasActiveFilters {
                    Section {
                        Button("Clear Filters", role: .destructive) {
                            Task {
                                await model.clearFilters()
                                dismiss()
                            }
                        }
                        .frame(minHeight: 44)
                    }
                }
            }
            .themedPageBackground()
            .navigationTitle("Card Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        Task {
                            await draft.apply(to: model)
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}

struct KanbanCardSummaryView: View {
    let card: KanbanCard
    var reservesTrailingActionSpace = false
    @ScaledMetric(relativeTo: .caption) private var stalenessIconSlot = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let priority = card.priority {
                    Text(verbatim: "P\(priority)")
                        .font(.caption.monospaced().weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.12), in: Capsule())
                }
                Text(card.cardID ?? String(localized: "Unknown Card"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.appSecondary)
                Spacer(minLength: 4)
                if let age = card.ageSeconds {
                    HStack(spacing: 3) {
                        Image(systemName: stalenessImage)
                            .frame(width: stalenessIconSlot)
                        Text(KanbanAgeFormatter.abbreviated(age))
                            .monospaced()
                    }
                        .font(AppFont.caption())
                        .foregroundStyle(stalenessColor)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            Text(card.title ?? String(localized: "Untitled Card"))
                .font(AppFont.headline())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, trailingActionInset)

            if let body = card.body, !body.isEmpty {
                Text(markdownPreview(body))
                    .font(AppFont.subheadline())
                    .foregroundStyle(.appSecondary)
                    .lineLimit(3)
                    .padding(.trailing, trailingActionInset)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    metadataLabels(locksHorizontalSize: true)
                }
                VStack(alignment: .leading, spacing: 5) {
                    metadataLabels(locksHorizontalSize: false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(AppFont.caption())
            .foregroundStyle(.appSecondary)
            .padding(.trailing, trailingActionInset)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(KanbanCardAccessibility.summary(card))
    }

    private var trailingActionInset: CGFloat {
        reservesTrailingActionSpace ? 44 : 0
    }

    @ViewBuilder
    private func metadataLabels(locksHorizontalSize: Bool) -> some View {
        metadataLabel(
            card.assignee ?? String(localized: "Unassigned"),
            systemImage: "person",
            locksHorizontalSize: locksHorizontalSize
        )
        if let tenant = card.tenant, !tenant.isEmpty {
            metadataLabel(
                tenant,
                systemImage: "building.2",
                locksHorizontalSize: locksHorizontalSize
            )
        }
        if let comments = card.commentCount, comments > 0 {
            metadataLabel(
                "\(comments)",
                systemImage: "bubble.left",
                locksHorizontalSize: locksHorizontalSize
            )
        }
        let dependencies = (card.linkCounts?.parents ?? 0) + (card.linkCounts?.children ?? 0)
        if dependencies > 0 {
            metadataLabel(
                "\(dependencies)",
                systemImage: "link",
                locksHorizontalSize: locksHorizontalSize
            )
        }
    }

    private func metadataLabel(
        _ title: String,
        systemImage: String,
        locksHorizontalSize: Bool
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: systemImage)
            Text(title)
        }
        .fixedSize(horizontal: locksHorizontalSize, vertical: false)
    }

    private var stalenessImage: String {
        switch card.staleness {
        case .none: "clock"
        case .warning: "clock.badge.exclamationmark"
        case .critical: "exclamationmark.triangle.fill"
        }
    }

    private var stalenessColor: Color {
        switch card.staleness {
        case .none: .secondary
        case .warning: .orange
        case .critical: .red
        }
    }

    private func markdownPreview(_ source: String) -> AttributedString {
        (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
    }
}

enum KanbanCardAccessibility {
    static func summary(_ card: KanbanCard) -> String {
        var parts = [
            card.cardID ?? String(localized: "Unknown Card"),
            card.title ?? String(localized: "Untitled Card"),
            KanbanStatusPresentation(card.status?.rawValue ?? "").title,
            card.assignee ?? String(localized: "Unassigned")
        ]
        if let tenant = card.tenant { parts.append(tenant) }
        if let comments = card.commentCount { parts.append(KanbanCountFormatter.comments(comments)) }
        let prerequisites = card.linkCounts?.parents ?? 0
        let dependents = card.linkCounts?.children ?? 0
        if prerequisites > 0 { parts.append(KanbanCountFormatter.prerequisites(prerequisites)) }
        if dependents > 0 { parts.append(KanbanCountFormatter.dependents(dependents)) }
        if let age = card.ageSeconds { parts.append(String(localized: "Age \(KanbanAgeFormatter.full(age))")) }
        return parts.joined(separator: ", ")
    }
}

enum KanbanBoardAccessibility {
    static func browseLabel(_ board: KanbanBoard) -> String {
        let boardName = board.name ?? board.slug ?? String(localized: "Board")
        return String.localizedStringWithFormat(String(localized: "Browse Board: %@"), boardName)
    }

    static func actionsLabel(_ board: KanbanBoard) -> String {
        let boardName = board.name ?? board.slug ?? String(localized: "Board")
        return String.localizedStringWithFormat(String(localized: "Board actions for %@"), boardName)
    }

    static func browseSummary(_ board: KanbanBoard, isActive: Bool) -> String {
        var parts = [browseLabel(board)]
        if let description = board.description?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            parts.append(description)
        }
        parts.append(KanbanCountFormatter.cards(board.total ?? 0))
        let status = statusValue(isBrowsing: false, isActive: isActive)
        if !status.isEmpty { parts.append(status) }
        return parts.joined(separator: ", ")
    }

    static func statusValue(isBrowsing: Bool, isActive: Bool) -> String {
        var statuses: [String] = []
        if isBrowsing { statuses.append(String(localized: "Browsing")) }
        if isActive { statuses.append(String(localized: "Active")) }
        return statuses.joined(separator: ", ")
    }
}

enum KanbanBoardRowAction: Equatable {
    case edit
    case makeActive
    case archive

    var systemImage: String {
        switch self {
        case .edit: "pencil"
        case .makeActive: "checkmark.circle"
        case .archive: "archivebox"
        }
    }
}

struct KanbanBoardRowPresentation: Equatable {
    let browseSlug: String?
    let actions: [KanbanBoardRowAction]
    let mutationsAreEnabled: Bool
    let isBrowsing: Bool
    let isActive: Bool

    init(
        board: KanbanBoard,
        selectedBoardSlug: String?,
        sharedActiveBoardSlug: String?,
        canManageBoards: Bool
    ) {
        let trimmedSlug = board.slug?.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = trimmedSlug?.isEmpty == false ? trimmedSlug : nil
        isBrowsing = slug != nil && slug == selectedBoardSlug
        isActive = slug != nil && slug == sharedActiveBoardSlug
        browseSlug = isBrowsing ? nil : slug
        mutationsAreEnabled = canManageBoards && slug != nil

        guard let slug else {
            actions = []
            return
        }
        var applicableActions: [KanbanBoardRowAction] = [.edit]
        if slug != sharedActiveBoardSlug {
            applicableActions.append(.makeActive)
        }
        if slug != "default" {
            applicableActions.append(.archive)
        }
        actions = applicableActions
    }
}

enum KanbanBulkAccessibility {
    static func selectionLabel(_ card: KanbanCard, isSelected: Bool) -> String {
        var parts = [KanbanCardAccessibility.summary(card)]
        if isSelected { parts.append(String(localized: "Selected")) }
        return parts.joined(separator: ", ")
    }

    static func resultLabel(_ summary: KanbanBulkActionSummary) -> String {
        [
            "\(summary.succeededCount) \(String(localized: "Complete"))",
            "\(summary.failedCount) \(String(localized: "Failed"))",
            "\(summary.uncertainCount) \(String(localized: "Outcome Uncertain"))"
        ].joined(separator: ", ")
    }
}

struct KanbanStatusPresentation {
    let rawValue: String

    init(_ rawValue: String) { self.rawValue = rawValue }

    var title: String {
        switch rawValue {
        case "triage": String(localized: "Triage")
        case "todo": String(localized: "To Do")
        case "scheduled": String(localized: "Scheduled")
        case "ready": String(localized: "Ready")
        case "running": String(localized: "Running")
        case "blocked": String(localized: "Blocked")
        case "review": String(localized: "Review")
        case "done": String(localized: "Done")
        case "archived": String(localized: "Archived")
        case "": String(localized: "Unknown Status")
        default: String(localized: "Unsupported: \(rawValue)")
        }
    }

    var color: Color {
        switch rawValue {
        case "triage": .gray
        case "todo": .blue
        case "scheduled": .indigo
        case "ready": .mint
        case "running": .orange
        case "blocked": .red
        case "review": .yellow
        case "done": .green
        case "archived": .secondary
        default: .purple
        }
    }
}

struct KanbanView: View {
    @State private var model: KanbanFeatureState

    init(server: URL, onAPIError: @escaping (Error) -> Void) {
        _model = State(
            initialValue: KanbanFeatureState(
                server: server,
                onAPIError: onAPIError
            )
        )
    }

    /// Kanban on a Hermes server, read through its saved connection's shared sign-in and kept
    /// live over its Kanban socket. A refused sign-in signs the server out through that
    /// connection, not `onAPIError`.
    /// `mine` is the Profile Only Mine shows: the one the Sessions side lists, as Kanban opens.
    init(server: URL, hermes connection: HermesConnection, mine: String?) {
        _model = State(
            initialValue: KanbanFeatureState(
                server: server,
                client: HermesKanbanClient(http: connection, mine: mine)
            )
        )
    }

    var body: some View {
        KanbanStatusFocusView(model: model)
            .onAppear { UsageReports.shared.record(.kanban) }
            .task {
                await model.loadIfNeeded()
            }
    }
}

enum KanbanAgeFormatter {
    static func abbreviated(_ seconds: Double) -> String { format(seconds, style: .abbreviated) }
    static func full(_ seconds: Double) -> String { format(seconds, style: .full) }

    private static func format(_ seconds: Double, style: DateComponentsFormatter.UnitsStyle) -> String {
        let formatter = switch (style, seconds) {
        case (.abbreviated, 86_400...): abbreviatedDays
        case (.abbreviated, 3_600...): abbreviatedHours
        case (.abbreviated, _): abbreviatedMinutes
        case (.full, 86_400...): fullDays
        case (.full, 3_600...): fullHours
        default: fullMinutes
        }
        return formatter.string(from: max(0, seconds)) ?? String(localized: "Just now")
    }

    private static let abbreviatedMinutes = makeFormatter(unit: .minute, style: .abbreviated)
    private static let abbreviatedHours = makeFormatter(unit: .hour, style: .abbreviated)
    private static let abbreviatedDays = makeFormatter(unit: .day, style: .abbreviated)
    private static let fullMinutes = makeFormatter(unit: .minute, style: .full)
    private static let fullHours = makeFormatter(unit: .hour, style: .full)
    private static let fullDays = makeFormatter(unit: .day, style: .full)

    private static func makeFormatter(
        unit: NSCalendar.Unit,
        style: DateComponentsFormatter.UnitsStyle
    ) -> DateComponentsFormatter {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = unit
        formatter.maximumUnitCount = 1
        formatter.unitsStyle = style
        return formatter
    }
}

enum KanbanCountFormatter {
    static func cards(_ count: Int) -> String { localized(count, key: "%lld Cards") }
    static func comments(_ count: Int) -> String { localized(count, key: "%lld comments") }
    static func prerequisites(_ count: Int) -> String { localized(count, key: "%lld Prerequisites") }
    static func dependents(_ count: Int) -> String { localized(count, key: "%lld Dependents") }

    private static func localized(_ count: Int, key: String.LocalizationValue) -> String {
        String.localizedStringWithFormat(String(localized: key), count)
    }
}
