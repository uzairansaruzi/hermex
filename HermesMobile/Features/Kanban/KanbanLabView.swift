import SwiftUI

enum KanbanCardAction: Equatable {
    case move(String)
    case block
    case unblock
    case complete
    case archive
}

struct KanbanPendingCardAction: Identifiable, Equatable {
    let id = UUID()
    let card: KanbanCard
    let action: KanbanCardAction

    static func == (lhs: KanbanPendingCardAction, rhs: KanbanPendingCardAction) -> Bool {
        lhs.id == rhs.id
    }
}

struct KanbanStatusFocusView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var model: KanbanFeatureState
    @State private var showsFilters = false
    @State private var visibleModel: KanbanFeatureState?
    @State private var cardEditor: KanbanCardEditorState?
    @State private var pendingRunningAction: KanbanPendingCardAction?
    @AccessibilityFocusState private var focusedCardID: String?
    @AccessibilityFocusState private var archiveUndoIsFocused: Bool

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
            }
        }
        .navigationTitle(String(localized: "Kanban"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $model.searchText, prompt: Text("Search Cards"))
        .toolbar { toolbarContent }
        .sheet(isPresented: $showsFilters) {
            KanbanFiltersView(model: model)
        }
        .sheet(item: $cardEditor) { editor in
            KanbanCardEditorView(
                state: editor,
                allowsMutation: model.canMutateCards,
                onSaved: { await model.reconcileAfterCardMutation() }
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
        let isActive = phase == .active
        Task { await model.setSceneActive(isActive) }
    }

    private var loadingContent: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading Kanban")
                .foregroundStyle(.secondary)
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
            statusSelector
            Divider()
            cardList
        }
    }

    private func archiveUndoBanner(_ undo: KanbanArchiveUndo) -> some View {
        let recoveryPhase = model.mutationState(for: undo.cardID)?.phase
        let statusText = recoveryPhase == .outcomeUncertain
            ? String(localized: "Outcome Uncertain")
            : recoveryPhase == .failed
                ? String(localized: "Update failed")
                : String(localized: "Archived")
        let hasRecoveryError = recoveryPhase == .outcomeUncertain || recoveryPhase == .failed
        return HStack {
            Label(
                statusText,
                systemImage: hasRecoveryError ? "exclamationmark.circle" : "archivebox"
            )
                .lineLimit(2)
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
        .font(.footnote)
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

    private var offlineBanner: some View {
        Label("Offline—showing previously loaded data", systemImage: "wifi.slash")
            .font(.footnote)
            .foregroundStyle(.orange)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12))
            .accessibilityLabel(Text("Offline—showing previously loaded data"))
    }

    private var liveUpdatesDelayedBanner: some View {
        Label("Live updates delayed", systemImage: "arrow.clockwise.circle")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.secondary.opacity(0.08))
            .accessibilityLabel(Text("Live updates delayed"))
    }

    private var compatibilityBanner: some View {
        Label {
            Text("Kanban is available with limited capabilities.")
                .font(.footnote)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.orange)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12))
    }

    private var refreshErrorBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label("Could not refresh this Board. Previously loaded Cards remain visible.", systemImage: "exclamationmark.triangle")
                .font(.footnote)
            Spacer(minLength: 4)
            Button("Try Again") { Task { await model.refresh() } }
                .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.red.opacity(0.1))
    }

    private var statusSelector: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(model.availableStatuses, id: \.self) { status in
                    let presentation = KanbanStatusPresentation(status)
                    Button {
                        model.selectedStatus = status
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(presentation.color)
                                .frame(width: 8, height: 8)
                            Text(presentation.title)
                            Text(verbatim: "\(model.statusCount(status))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline.weight(model.selectedStatus == status ? .semibold : .regular))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(
                            model.selectedStatus == status ? Color.secondary.opacity(0.16) : Color.clear,
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        String.localizedStringWithFormat(
                            String(localized: "%@, %@"),
                            presentation.title,
                            KanbanCountFormatter.cards(model.statusCount(status))
                        )
                    )
                    .accessibilityAddTraits(model.selectedStatus == status ? .isSelected : [])
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
    }

    private var cardList: some View {
        List {
            if model.isRefreshing {
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
                ForEach(Array(model.groupedVisibleCards.enumerated()), id: \.offset) { _, group in
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

    private func cardNavigationLink(_ card: KanbanCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                NavigationLink {
                    if let cardID = card.cardID {
                        KanbanCardDetailView(featureModel: model, cardID: cardID)
                    }
                } label: {
                    KanbanCardSummaryView(card: card)
                }
                cardActionsMenu(card)
            }
            mutationStatus(for: card)
        }
        .accessibilityFocused($focusedCardID, equals: card.cardID)
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
            } else if card.status?.rawValue != "archived" {
                Button("Block") { request(.block, for: card) }
            }
            if card.status?.rawValue != "done", card.status?.rawValue != "archived" {
                Button("Complete") { request(.complete, for: card) }
            }
            if card.status?.rawValue != "archived" {
                Button("Archive", role: .destructive) { request(.archive, for: card) }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(minWidth: 44, minHeight: 44)
        }
        .disabled(!model.canMutateCard(card) || model.isMutatingCard(card.cardID))
        .accessibilityLabel(Text("Card Actions"))
    }

    @ViewBuilder
    private func mutationStatus(for card: KanbanCard) -> some View {
        if let mutation = model.mutationState(for: card.cardID) {
            switch mutation.phase {
            case .updating:
                Label("Updating task...", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote).foregroundStyle(.secondary)
            case .checkingResult:
                Label("Checking Result", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote).foregroundStyle(.secondary)
            case .succeeded:
                Label("Updated", systemImage: "checkmark.circle.fill")
                    .font(.footnote).foregroundStyle(.green)
            case .failed:
                HStack {
                    Label("Update failed", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                    Button("Try Again") { retryMutation(for: card) }
                }
                .font(.footnote)
            case .outcomeUncertain:
                HStack {
                    Label("Outcome Uncertain", systemImage: "questionmark.circle")
                        .foregroundStyle(.orange)
                    Button("Refresh") { Task { await model.checkUncertainMutation(for: card) } }
                }
                .font(.footnote)
            }
        }
    }

    private func request(_ action: KanbanCardAction, for card: KanbanCard) {
        if card.status?.rawValue == "running" {
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
            case let .move(status):
                await model.moveCard(card, to: status, confirmingRunningExit: confirmingRunningExit)
                if model.mutationState(for: card.cardID)?.phase == .succeeded {
                    model.selectedStatus = status
                    await Task.yield()
                    focusedCardID = card.cardID
                }
            case .block:
                await model.blockCard(card, reason: nil, confirmingRunningExit: confirmingRunningExit)
                if model.mutationState(for: card.cardID)?.phase == .succeeded {
                    model.selectedStatus = "blocked"
                    await Task.yield()
                    focusedCardID = card.cardID
                }
            case .unblock:
                await model.unblockCard(card)
                if model.mutationState(for: card.cardID)?.phase == .succeeded {
                    model.selectedStatus = "ready"
                    await Task.yield()
                    focusedCardID = card.cardID
                }
            case .complete:
                await model.completeCard(card, confirmingRunningExit: confirmingRunningExit)
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
        case let .status(status): request(status == "done" ? .complete : .move(status), for: card)
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
            } label: {
                HStack(spacing: 4) {
                    Text(model.selectedBoard?.name ?? model.selectedBoardSlug ?? String(localized: "Board"))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .frame(minHeight: 44)
            }
            .accessibilityLabel(String(localized: "Switch Board"))
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                cardEditor = model.makeCreateCardEditorState()
            } label: {
                Image(systemName: "plus")
            }
            .disabled(!model.canMutateCards)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(Text("New Card"))

            Button {
                model.groupByProfile.toggle()
            } label: {
                Image(systemName: model.groupByProfile ? "person.2.fill" : "person.2")
            }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(model.groupByProfile ? Text("Stop grouping by Profile") : Text("Group by Profile"))

            Button {
                showsFilters = true
            } label: {
                Image(systemName: model.hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(Text("Card Filters"))
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

private struct KanbanFiltersView: View {
    @Environment(\.dismiss) private var dismiss
    let model: KanbanFeatureState
    @State private var profile: String?
    @State private var tenant: String?
    @State private var includesArchived: Bool
    @State private var onlyMine: Bool

    init(model: KanbanFeatureState) {
        self.model = model
        _profile = State(initialValue: model.selectedProfile)
        _tenant = State(initialValue: model.selectedTenant)
        _includesArchived = State(initialValue: model.includeArchived)
        _onlyMine = State(initialValue: model.onlyMine)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    Picker("Assigned Profile", selection: $profile) {
                        Text("All Profiles").tag(String?.none)
                        ForEach(model.profileOptions, id: \.self) { value in
                            Text(value).tag(Optional(value))
                        }
                    }
                    .disabled(onlyMine)
                    Toggle("Only Mine", isOn: $onlyMine)
                        .onChange(of: onlyMine) { _, enabled in
                            if enabled { profile = nil }
                        }
                }

                Section("Tenant") {
                    Picker("Tenant", selection: $tenant) {
                        Text("All Tenants").tag(String?.none)
                        ForEach(model.tenantOptions, id: \.self) { value in
                            Text(value).tag(Optional(value))
                        }
                    }
                }

                Section("Archived Cards") {
                    Toggle("Include Archived Cards", isOn: $includesArchived)
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
            .navigationTitle("Card Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        Task {
                            await model.applyFilters(
                                profile: profile,
                                tenant: tenant,
                                includeArchived: includesArchived,
                                onlyMine: onlyMine
                            )
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
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let age = card.ageSeconds {
                    Label(KanbanAgeFormatter.abbreviated(age), systemImage: stalenessImage)
                        .font(.caption)
                        .foregroundStyle(stalenessColor)
                }
            }

            Text(card.title ?? String(localized: "Untitled Card"))
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let body = card.body, !body.isEmpty {
                Text(markdownPreview(body))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { metadataLabels }
                VStack(alignment: .leading, spacing: 5) { metadataLabels }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(KanbanCardAccessibility.summary(card))
    }

    @ViewBuilder
    private var metadataLabels: some View {
        Label(card.assignee ?? String(localized: "Unassigned"), systemImage: "person")
        if let tenant = card.tenant, !tenant.isEmpty {
            Label(tenant, systemImage: "building.2")
        }
        if let comments = card.commentCount, comments > 0 {
            Label("\(comments)", systemImage: "bubble.left")
        }
        let dependencies = (card.linkCounts?.parents ?? 0) + (card.linkCounts?.children ?? 0)
        if dependencies > 0 {
            Label("\(dependencies)", systemImage: "link")
        }
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

struct KanbanStatusPresentation {
    let rawValue: String

    init(_ rawValue: String) { self.rawValue = rawValue }

    var title: String {
        switch rawValue {
        case "triage": String(localized: "Triage")
        case "todo": String(localized: "To Do")
        case "ready": String(localized: "Ready")
        case "running": String(localized: "Running")
        case "blocked": String(localized: "Blocked")
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
        case "ready": .mint
        case "running": .orange
        case "blocked": .red
        case "done": .green
        case "archived": .secondary
        default: .purple
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

#if DEBUG
struct KanbanLabView: View {
    @State private var scenario = KanbanLabScenario.dense
    @State private var model = KanbanLabScenario.dense.makeModel()

    var body: some View {
        KanbanStatusFocusView(model: model)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Scenario", selection: $scenario) {
                            ForEach(KanbanLabScenario.allCases) { scenario in
                                Text(scenario.title).tag(scenario)
                            }
                        }
                    } label: {
                        Image(systemName: "testtube.2")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(Text("Kanban Lab Scenario"))
                    .accessibilityHint(Text("Uses local fixtures and never contacts or changes a Kanban server."))
                }
            }
            .task(id: scenario) {
                model = scenario.makeModel()
                await model.load()
                if scenario == .filteredEmpty { model.searchText = "no matching fixture" }
            }
    }
}

enum KanbanLabScenario: String, CaseIterable, Identifiable {
    case firstLoad
    case dense
    case empty
    case filteredEmpty
    case partial
    case authentication
    case network
    case serverUnavailable
    case incompatible
    case liveDelayed
    case offline
    case detailEmpty
    case detailError
    case detailTruncated

    var id: String { rawValue }

    var title: String {
        switch self {
        case .firstLoad: "First load"
        case .dense: "Dense Board"
        case .empty: "Empty Board"
        case .filteredEmpty: "Filtered empty"
        case .partial: "Partial capability"
        case .authentication: "Authentication"
        case .network: "Network"
        case .serverUnavailable: "Server unavailable"
        case .incompatible: "Incompatible"
        case .liveDelayed: "Live updates delayed"
        case .offline: "Offline snapshot"
        case .detailEmpty: "Empty Card detail"
        case .detailError: "Card detail error"
        case .detailTruncated: "Truncated worker log"
        }
    }

    @MainActor
    func makeModel() -> KanbanFeatureState {
        KanbanFeatureState(
            server: URL(string: "https://kanban-lab.invalid")!,
            client: KanbanLabClient(scenario: self),
            streamClient: KanbanLabStreamClient(fails: self == .liveDelayed || self == .offline),
            timing: KanbanLiveUpdateTiming(
                coalescingDelay: .milliseconds(10),
                reconnectDelays: [.milliseconds(10), .milliseconds(10)],
                pollingInterval: self == .offline ? .milliseconds(10) : .seconds(30),
                failuresBeforePolling: 3
            )
        )
    }
}

actor KanbanLabClient: KanbanDataClient {
    let scenario: KanbanLabScenario
    private var submittedComments: [String] = []
    private var storedCards: [String: [String: StoredCard]] = [:]
    private var cardIDsByIntent: [String: String] = [:]
    private var nextCardSequence = 100

    init(scenario: KanbanLabScenario) { self.scenario = scenario }

    func kanbanConfiguration() async throws -> KanbanConfiguration {
        if scenario == .firstLoad { try await Task.sleep(for: .seconds(2)) }
        switch scenario {
        case .authentication: throw APIError.unauthorized
        case .network: throw APIError.network(underlying: URLError(.notConnectedToInternet))
        case .serverUnavailable: throw APIError.http(statusCode: 503, body: nil)
        default:
            return decode(#"{"columns":["triage","todo","ready","running","blocked","done"],"assignees":["builder","reviewer"],"read_only":false}"#)
        }
    }

    func kanbanBoards() throws -> KanbanBoardsResponse {
        decode(#"{"boards":[{"slug":"main","name":"Main Board","total":8},{"slug":"release","name":"Release Board","total":2}],"current":"main","read_only":false}"#)
    }

    func kanbanBoard(_ request: KanbanBoardRequest) throws -> KanbanBoardSnapshot {
        if scenario == .incompatible {
            return decode(#"{"changed":true,"read_only":false,"columns":[{"name":"ready","tasks":[{"title":"Missing identity","status":"ready"}]}]}"#)
        }
        if scenario == .empty {
            return decode(#"{"changed":true,"latest_event_id":1,"read_only":false,"columns":[{"name":"triage","tasks":[]},{"name":"todo","tasks":[]},{"name":"ready","tasks":[]},{"name":"running","tasks":[]},{"name":"blocked","tasks":[]},{"name":"done","tasks":[]}],"tenants":[],"assignees":[]}"#)
        }
        if request.since != nil {
            return decode(#"{"changed":false,"latest_event_id":9,"read_only":false}"#)
        }
        return decode(snapshotObject(for: request))
    }

    func kanbanStats(board: String) throws -> KanbanStats {
        if scenario == .partial { throw APIError.http(statusCode: 404, body: nil) }
        return decode(#"{"by_status":{"triage":1,"todo":1,"ready":2,"running":1,"blocked":1,"done":1},"by_assignee":{"builder":4,"reviewer":2,"unassigned":1}}"#)
    }

    func kanbanAssignees(board: String) throws -> KanbanAssigneeHistory {
        decode(#"{"assignees":["builder","reviewer","release"]}"#)
    }

    func kanbanEvents(_ request: KanbanEventsRequest) throws -> KanbanEventsEnvelope {
        if scenario == .offline {
            throw APIError.network(underlying: URLError(.notConnectedToInternet))
        }
        return decode(#"{"events":[],"cursor":9,"latest_event_id":9,"read_only":false}"#)
    }

    func kanbanCardDetail(_ request: KanbanCardDetailRequest) async throws -> KanbanCardDetailEnvelope {
        if scenario == .detailError { throw APIError.http(statusCode: 503, body: nil) }
        if let stored = storedCards[request.board]?[request.cardID] {
            return decode([
                "task": stored.object,
                "comments": [],
                "events": [],
                "links": [
                    "parents": stored.prerequisiteID.map { [$0] } ?? [],
                    "children": []
                ],
                "runs": [],
                "read_only": false
            ])
        }
        let isEmpty = scenario == .detailEmpty
        var comments: [[String: Any]] = isEmpty ? [] : [
            ["id": 1, "task_id": request.cardID, "author": "reviewer", "body": "Looks good from the review side.", "created_at": 1_700_000_000]
        ]
        comments += submittedComments.enumerated().map { offset, body in
            ["id": offset + 2, "task_id": request.cardID, "author": "webui", "body": body, "created_at": 1_700_000_100 + offset]
        }
        let payload: [String: Any] = [
            "task": [
                "id": request.cardID,
                "title": isEmpty ? "Empty history fixture" : "Implement Status Focus",
                "body": isEmpty ? "" : "This **Markdown** description stays selectable.",
                "status": "ready",
                "assignee": "builder",
                "tenant": "app",
                "priority": 1,
                "created_at": 1_699_999_000,
                "updated_at": 1_700_000_000,
                "workspace_kind": "worktree",
                "workspace_path": "/private/fixture/explicit-history-only",
                "skills": ["swiftui-patterns"],
                "max_runtime_seconds": 3600,
                "current_run_id": "run-fixture",
                "claim_lock": "claim-fixture",
                "worker_pid": 4242
            ],
            "comments": comments,
            "events": isEmpty ? [] : [[
                "id": 9, "task_id": request.cardID, "kind": "status",
                "payload": ["status": "ready", "secret": "discarded"], "created_at": 1_700_000_000
            ]],
            "links": isEmpty ? ["parents": [], "children": []] : ["parents": ["CARD-1"], "children": ["CARD-7"]],
            "runs": isEmpty ? [] : [[
                "id": "run-fixture", "status": "finished", "outcome": "success",
                "summary": "Validated the focused suite.", "worker": "worker-fixture",
                "started_at": 1_699_999_500, "finished_at": 1_700_000_000
            ]],
            "read_only": false
        ]
        return decode(payload)
    }

    func kanbanWorkerLog(_ request: KanbanWorkerLogRequest) async throws -> KanbanWorkerLog {
        if scenario == .detailError { throw APIError.http(statusCode: 503, body: nil) }
        if scenario == .detailEmpty {
            return decode(["task_id": request.cardID, "exists": false, "size_bytes": 0, "content": "", "truncated": false])
        }
        return decode([
            "task_id": request.cardID,
            "path": "/private/fixture/not-retained",
            "exists": true,
            "size_bytes": 131_072,
            "content": "Focused tests passed.\nFull suite queued.\n",
            "truncated": scenario == .detailTruncated
        ])
    }

    func addKanbanComment(_ request: KanbanAddCommentRequest) async throws -> KanbanAddCommentResponse {
        submittedComments.append(request.body)
        return decode(["ok": true, "comment_id": submittedComments.count + 1, "read_only": false])
    }

    func createKanbanCard(_ request: KanbanCreateCardRequest) async throws -> KanbanCardMutationEnvelope {
        let intentKey = "\(request.board)\u{1F}\(request.idempotencyKey)"
        if let cardID = cardIDsByIntent[intentKey],
           let existing = storedCards[request.board]?[cardID] {
            return mutationEnvelope(for: existing)
        }

        let cardID = "CARD-LAB-\(nextCardSequence)"
        nextCardSequence += 1
        let card = StoredCard(cardID: cardID, request: request)
        storedCards[request.board, default: [:]][cardID] = card
        cardIDsByIntent[intentKey] = cardID
        return mutationEnvelope(for: card)
    }

    func editKanbanCard(_ request: KanbanEditCardRequest) async throws -> KanbanCardMutationEnvelope {
        let existing = storedCards[request.board]?[request.cardID]
            ?? fixtureCard(cardID: request.cardID)
        guard var card = existing else {
            throw APIError.http(statusCode: 404, body: nil)
        }
        card.apply(request)
        storedCards[request.board, default: [:]][request.cardID] = card
        return mutationEnvelope(for: card)
    }

    private func mutationEnvelope(for card: StoredCard) -> KanbanCardMutationEnvelope {
        decode(["task": card.object, "read_only": false])
    }

    private func snapshotObject(for request: KanbanBoardRequest) -> [String: Any] {
        let data = Data(snapshotJSON(for: request).utf8)
        var snapshot = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        var columns = snapshot["columns"] as! [[String: Any]]
        let cards = storedCards[request.board].map { Array($0.values) } ?? []
        let replacedIDs = Set(cards.map(\.cardID))

        for index in columns.indices {
            let existing = columns[index]["tasks"] as? [[String: Any]] ?? []
            columns[index]["tasks"] = existing.filter {
                guard let cardID = $0["id"] as? String else { return true }
                return !replacedIDs.contains(cardID)
            }
        }

        for card in cards where card.matches(request) {
            guard let index = columns.firstIndex(where: { $0["name"] as? String == card.status }) else {
                continue
            }
            var values = columns[index]["tasks"] as? [[String: Any]] ?? []
            values.append(card.object)
            columns[index]["tasks"] = values
        }
        snapshot["columns"] = columns
        return snapshot
    }

    private func fixtureCard(cardID: String) -> StoredCard? {
        guard (1...8).contains(Int(cardID.replacingOccurrences(of: "CARD-", with: "")) ?? -1) else {
            return nil
        }
        return StoredCard(
            cardID: cardID,
            title: "Implement Status Focus",
            body: "This **Markdown** description stays selectable.",
            status: "ready",
            priority: 1,
            assignee: "builder",
            tenant: "app",
            workspaceKind: "worktree",
            workspacePath: "/private/fixture/explicit-history-only",
            skills: ["swiftui-patterns"],
            maxRuntimeSeconds: 3_600,
            prerequisiteID: "CARD-1"
        )
    }

    private func snapshotJSON(for request: KanbanBoardRequest) -> String {
        let archived = request.includeArchived
            ? #",{"name":"archived","tasks":[{"id":"CARD-8","title":"Retired experiment","status":"archived","assignee":null,"priority":0,"age_seconds":172800}]}"#
            : ""
        let unknown = scenario == .partial
            ? #",{"name":"awaiting-review","tasks":[{"id":"CARD-9","title":"Future server Status remains visible","status":"awaiting-review","assignee":"reviewer","priority":1,"age_seconds":120}]}"#
            : ""
        let all = """
        {"changed":true,"latest_event_id":9,"read_only":false,"tenants":["app","ops"],"assignees":["builder","reviewer"],"columns":[
          {"name":"triage","tasks":[{"id":"CARD-1","title":"Shape the next slice","body":"Review **requirements** and capture decisions.","status":"triage","assignee":null,"tenant":"app","priority":2,"comment_count":2,"link_counts":{"parents":0,"children":1},"age_seconds":300}]},
          {"name":"todo","tasks":[{"id":"CARD-2","title":"Prepare fixtures","body":"- Dense Board\\n- Empty Board\\n- Error state","status":"todo","assignee":"builder","tenant":"app","priority":1,"comment_count":1,"link_counts":{"parents":1,"children":0},"age_seconds":1800}]},
          {"name":"ready","tasks":[{"id":"CARD-3","title":"Implement Status Focus","body":"Keep Card identity stable through refresh.","status":"ready","assignee":"builder","tenant":"app","priority":0,"comment_count":4,"link_counts":{"parents":0,"children":2},"age_seconds":7200},{"id":"CARD-4","title":"Audit localized copy","status":"ready","assignee":"reviewer","tenant":"app","priority":2,"comment_count":0,"link_counts":{"parents":0,"children":0},"age_seconds":600}]},
          {"name":"running","tasks":[{"id":"CARD-5","title":"Run the full XCTest suite","status":"running","assignee":"builder","tenant":"ops","priority":0,"comment_count":1,"link_counts":{"parents":0,"children":0},"age_seconds":4200}]},
          {"name":"blocked","tasks":[{"id":"CARD-6","title":"Await owner validation","body":"> Required before PR publication","status":"blocked","assignee":"reviewer","tenant":"ops","priority":1,"comment_count":3,"link_counts":{"parents":1,"children":0},"age_seconds":90000}]},
          {"name":"done","tasks":[{"id":"CARD-7","title":"Verify read contracts","status":"done","assignee":"builder","tenant":"ops","priority":0,"comment_count":0,"link_counts":{"parents":0,"children":1},"age_seconds":3600}]}
          \(archived)\(unknown)
        ]}
        """
        if request.onlyMine || request.assignee == "builder" {
            return all.replacingOccurrences(of: #",{"id":"CARD-4","title":"Audit localized copy","status":"ready","assignee":"reviewer","tenant":"app","priority":2,"comment_count":0,"link_counts":{"parents":0,"children":0},"age_seconds":600}"#, with: "")
        }
        return all
    }

    private func decode<T: Decodable>(_ json: String) -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(T.self, from: Data(json.utf8))
    }

    private func decode<T: Decodable>(_ object: Any) -> T {
        let data = try! JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(T.self, from: data)
    }

    private struct StoredCard: Sendable {
        let cardID: String
        var title: String
        var body: String?
        var status: String
        var priority: Int
        var assignee: String?
        var tenant: String?
        let workspaceKind: String
        let workspacePath: String?
        let skills: [String]?
        let maxRuntimeSeconds: Int?
        let prerequisiteID: String?

        init(
            cardID: String,
            title: String,
            body: String?,
            status: String,
            priority: Int,
            assignee: String?,
            tenant: String?,
            workspaceKind: String,
            workspacePath: String?,
            skills: [String]?,
            maxRuntimeSeconds: Int?,
            prerequisiteID: String?
        ) {
            self.cardID = cardID
            self.title = title
            self.body = body
            self.status = status
            self.priority = priority
            self.assignee = assignee
            self.tenant = tenant
            self.workspaceKind = workspaceKind
            self.workspacePath = workspacePath
            self.skills = skills
            self.maxRuntimeSeconds = maxRuntimeSeconds
            self.prerequisiteID = prerequisiteID
        }

        init(cardID: String, request: KanbanCreateCardRequest) {
            self.init(
                cardID: cardID,
                title: request.title,
                body: request.body,
                status: request.status,
                priority: request.priority ?? 0,
                assignee: request.assignee,
                tenant: request.tenant,
                workspaceKind: request.workspaceKind,
                workspacePath: request.workspacePath,
                skills: request.skills,
                maxRuntimeSeconds: request.maxRuntimeSeconds,
                prerequisiteID: request.prerequisiteID
            )
        }

        mutating func apply(_ request: KanbanEditCardRequest) {
            title = request.title
            body = request.body
            tenant = request.tenant
            priority = request.priority
            assignee = request.assignee
            if let status = request.status { self.status = status }
        }

        func matches(_ request: KanbanBoardRequest) -> Bool {
            if status == "archived", !request.includeArchived { return false }
            if let tenant = request.tenant, self.tenant != tenant { return false }
            if let assignee = request.assignee, self.assignee != assignee { return false }
            if request.onlyMine, assignee != "builder" { return false }
            return true
        }

        var object: [String: Any] {
            var result: [String: Any] = [
                "id": cardID,
                "title": title,
                "status": status,
                "priority": priority,
                "workspace_kind": workspaceKind,
                "comment_count": 0,
                "age_seconds": 0
            ]
            if let body { result["body"] = body }
            if let assignee { result["assignee"] = assignee }
            if let tenant { result["tenant"] = tenant }
            if let workspacePath { result["workspace_path"] = workspacePath }
            if let skills { result["skills"] = skills }
            if let maxRuntimeSeconds { result["max_runtime_seconds"] = maxRuntimeSeconds }
            return result
        }
    }
}

@MainActor
private final class KanbanLabStreamClient: KanbanEventStreamingClient {
    private let fails: Bool
    private var callbackTask: Task<Void, Never>?

    init(fails: Bool) { self.fails = fails }

    func start(
        url: URL,
        onFrame: @escaping @MainActor (KanbanStreamFrame) -> Void,
        onFailure: @escaping @MainActor () -> Void
    ) {
        stop()
        callbackTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            if fails {
                onFailure()
            } else {
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let board = components?.queryItems?.first(where: { $0.name == "board" })?.value ?? "main"
                let cursor = Int(components?.queryItems?.first(where: { $0.name == "since" })?.value ?? "0") ?? 0
                onFrame(.hello(cursor: cursor, board: board))
            }
        }
    }

    func stop() {
        callbackTask?.cancel()
        callbackTask = nil
    }
}
#endif
