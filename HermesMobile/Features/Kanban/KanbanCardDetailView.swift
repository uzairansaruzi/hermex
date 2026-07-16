import SwiftUI

struct KanbanCardDetailView: View {
    let featureModel: KanbanFeatureState
    @State private var state: KanbanCardDetailState?

    init(featureModel: KanbanFeatureState, cardID: String) {
        self.featureModel = featureModel
        _state = State(initialValue: featureModel.makeCardDetailState(cardID: cardID))
    }

    var body: some View {
        Group {
            if let state {
                KanbanCardDetailContent(featureModel: featureModel, state: state)
            } else {
                ContentUnavailableView("Unavailable", systemImage: "exclamationmark.triangle")
            }
        }
        .navigationTitle(state?.detail?.card?.title ?? String(localized: "Loading"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct KanbanCardDetailContent: View {
    let featureModel: KanbanFeatureState
    @Bindable var state: KanbanCardDetailState
    @State private var showsOperationalHistory = false
    @State private var cardEditor: KanbanCardEditorState?
    @FocusState private var commentFieldIsFocused: Bool

    var body: some View {
        Group {
            switch state.loadState {
            case .idle, .loading:
                ProgressView("Loading")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                detailList
            case .missingCard:
                unavailable(
                    title: "No Content",
                    detail: "This Card no longer exists on this Board. The Board has been refreshed.",
                    systemImage: "rectangle.portrait.slash"
                )
            case .missingBoard:
                unavailable(
                    title: "No Content",
                    detail: "This Board no longer exists. Return to Kanban to choose another Board.",
                    systemImage: "rectangle.stack.badge.minus"
                )
            case .failed:
                unavailable(
                    title: "Error",
                    detail: "The server response could not be read.",
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
        .task { await state.load() }
        .task(id: featureModel.detailRefreshRevision) {
            await state.reconcile(revision: featureModel.detailRefreshRevision)
        }
        .onChange(of: state.commentSubmission) { _, submission in
            if submission == .validationFailed || submission == .failed {
                commentFieldIsFocused = true
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") {
                    guard let detail = state.detail else { return }
                    cardEditor = featureModel.makeEditCardEditorState(detail: detail)
                }
                .disabled(!featureModel.canMutateCards || state.loadState != .loaded)
            }
        }
        .sheet(item: $cardEditor) { editor in
            KanbanCardEditorView(
                state: editor,
                allowsMutation: featureModel.canMutateCards,
                onSaved: {
                    await featureModel.reconcileAfterCardMutation()
                    await state.refresh()
                }
            )
        }
    }

    private var detailList: some View {
        List {
            if featureModel.isOffline || featureModel.loadedDetailIsStale {
                Label("Offline—showing previously loaded data", systemImage: "wifi.slash")
                    .foregroundStyle(.orange)
                    .accessibilityLabel(Text("Offline—showing previously loaded data"))
            }

            if let card = state.detail?.card {
                descriptionSection(card)
                metadataSection(card)
            }
            commentsSection
            dependenciesSection
            operationalHistorySection
        }
        .refreshable { await state.refresh() }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func descriptionSection(_ card: KanbanCard) -> some View {
        Section("Description") {
            if let body = nonEmpty(card.body) {
                MarkdownRenderer(content: body)
                    .textSelection(.enabled)
            } else {
                Text("No Content")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func metadataSection(_ card: KanbanCard) -> some View {
        Section("Metadata") {
            LabeledContent("Card ID") { selectable(card.cardID) }
            LabeledContent("Status") {
                Text(KanbanStatusPresentation(card.status?.rawValue ?? "").title)
            }
            LabeledContent("Profile") {
                Text(card.assignee ?? String(localized: "Unassigned"))
            }
            if let tenant = nonEmpty(card.tenant) {
                LabeledContent("Tenant") { Text(verbatim: tenant).textSelection(.enabled) }
            }
            if let priority = card.priority {
                LabeledContent("Priority") { Text(verbatim: "P\(priority)") }
            }
            if let created = KanbanDetailDateFormatter.format(card.createdAt) {
                LabeledContent("Created") { Text(verbatim: created) }
            }
            if let updated = KanbanDetailDateFormatter.format(card.updatedAt) {
                LabeledContent("Updated") { Text(verbatim: updated) }
            }
            if let skills = card.skills, !skills.isEmpty {
                LabeledContent("Skills") {
                    Text(verbatim: skills.joined(separator: ", ")).textSelection(.enabled)
                }
            }
            if let runtime = card.maxRuntimeSeconds {
                LabeledContent("Maximum Runtime") {
                    Text(KanbanDurationFormatter.full(runtime))
                }
            }
        }
    }

    private var commentsSection: some View {
        Section {
            let comments = state.detail?.comments ?? []
            if comments.isEmpty {
                Text("No Content")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(comments, id: \.presentationID) { comment in
                    VStack(alignment: .leading) {
                        if let body = nonEmpty(comment.body) {
                            MarkdownRenderer(content: body)
                                .textSelection(.enabled)
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack { commentMetadata(comment) }
                            VStack(alignment: .leading) { commentMetadata(comment) }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            TextField("Comment", text: $state.commentDraft, axis: .vertical)
                .lineLimit(2...6)
                .focused($commentFieldIsFocused)
                .disabled(!featureModel.canAddComments || state.commentSubmission.isInFlight)
                .accessibilityHint(Text("Comments cannot be edited or deleted after sending."))

            Button {
                Task { await state.submitComment(allowsMutation: featureModel.canAddComments) }
            } label: {
                if state.commentSubmission.isInFlight {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text(state.commentSubmission == .failed ? "Try Again" : "Send")
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(!featureModel.canAddComments || !state.canSubmitDraft)
            .frame(minHeight: 44)

            commentSubmissionMessage
        } header: {
            Text(KanbanCountFormatter.comments(state.detail?.comments?.count ?? 0))
        } footer: {
            if !featureModel.canAddComments, featureModel.isOffline {
                Text("Offline Data")
            } else if !featureModel.canAddComments {
                Text("Read-only")
            }
        }
    }

    @ViewBuilder
    private var commentSubmissionMessage: some View {
        switch state.commentSubmission {
        case .idle:
            EmptyView()
        case .validationFailed:
            Label("Comment cannot be blank.", systemImage: "exclamationmark.circle")
                .foregroundStyle(.red)
        case .submitting:
            Label("Loading", systemImage: "paperplane")
        case .checkingResult:
            Label("Checking Result", systemImage: "arrow.triangle.2.circlepath")
        case .succeeded:
            Label("Added", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.circle")
                .foregroundStyle(.red)
        case .outcomeUncertain:
            VStack(alignment: .leading) {
                Label("Outcome Uncertain", systemImage: "questionmark.circle")
                    .foregroundStyle(.orange)
                Text("Refresh to check the Card before trying again.")
                    .font(.footnote)
                Button("Refresh") { Task { await state.refresh() } }
            }
        }
    }

    private var dependenciesSection: some View {
        Section("Dependencies") {
            dependencyGroup(
                title: KanbanCountFormatter.prerequisites(state.detail?.links?.prerequisites?.count ?? 0),
                ids: state.detail?.links?.prerequisites ?? []
            )
            dependencyGroup(
                title: KanbanCountFormatter.dependents(state.detail?.links?.dependents?.count ?? 0),
                ids: state.detail?.links?.dependents ?? []
            )
        }
    }

    @ViewBuilder
    private func dependencyGroup(title: String, ids: [String]) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline)
            if !ids.isEmpty {
                ForEach(ids, id: \.self) { id in
                    Text(verbatim: id)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var operationalHistorySection: some View {
        Section("Operational History") {
            if !showsOperationalHistory {
                Button("View all") {
                    showsOperationalHistory = true
                }
                .frame(minHeight: 44)
            } else {
                eventsContent
                dispatchRunsContent
                sensitiveMetadataContent
                workerLogContent
            }
        }
    }

    private var eventsContent: some View {
        DisclosureGroup("Events") {
            let events = state.detail?.events ?? []
            if events.isEmpty {
                Text("No Content").foregroundStyle(.secondary)
            } else {
                ForEach(events, id: \.presentationID) { event in
                    VStack(alignment: .leading) {
                        Text(verbatim: eventSummary(event))
                            .textSelection(.enabled)
                        if let date = KanbanDetailDateFormatter.format(event.createdAt) {
                            Text(verbatim: date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var dispatchRunsContent: some View {
        DisclosureGroup("Dispatch Runs") {
            let runs = state.detail?.runs ?? []
            if runs.isEmpty {
                Text("No Content").foregroundStyle(.secondary)
            } else {
                ForEach(runs, id: \.presentationID) { run in
                    VStack(alignment: .leading) {
                        Text(verbatim: [run.status, run.outcome].compactMap { $0 }.joined(separator: " · "))
                            .font(.headline)
                        if let summary = nonEmpty(run.summary) {
                            Text(verbatim: summary).textSelection(.enabled)
                        }
                        if let error = nonEmpty(run.error) {
                            Text(verbatim: error)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                        }
                        if let range = runDateRange(run) {
                            Text(verbatim: range)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let runID = nonEmpty(run.runID) {
                            LabeledContent("Run ID") { selectable(runID) }
                        }
                        if let workerID = nonEmpty(run.workerID) {
                            LabeledContent("Worker ID") { selectable(workerID) }
                        }
                        if let tail = nonEmpty(run.logTail) {
                            Text(verbatim: tail)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var sensitiveMetadataContent: some View {
        if let card = state.detail?.card {
            DisclosureGroup("Operational Metadata") {
                if let kind = nonEmpty(card.workspaceKind) {
                    LabeledContent("Workspace") { selectable(kind) }
                }
                if let path = nonEmpty(card.workspacePath) {
                    selectable(path)
                }
                if let runID = nonEmpty(card.currentRunID) {
                    LabeledContent("Run ID") { selectable(runID) }
                }
                if let claim = nonEmpty(card.claimLock) {
                    LabeledContent("Claim ID") { selectable(claim) }
                }
                if let expiry = KanbanDetailDateFormatter.format(card.claimExpires) {
                    LabeledContent("Claim Expires") { Text(verbatim: expiry) }
                }
                if let worker = nonEmpty(card.workerID) {
                    LabeledContent("Worker ID") { selectable(worker) }
                }
            }
        }
    }

    @ViewBuilder
    private var workerLogContent: some View {
        DisclosureGroup("Worker Log") {
            switch state.workerLogState {
            case .idle:
                Button("Load Worker Log") { Task { await state.loadWorkerLog() } }
                    .frame(minHeight: 44)
            case .loading:
                ProgressView("Loading")
            case .absent:
                Text("No Content")
                    .foregroundStyle(.secondary)
            case let .loaded(log):
                if log.truncated == true {
                    Label("Only the last part of this log is shown.", systemImage: "scissors")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Text(verbatim: log.content ?? "")
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                Button("Refresh") { Task { await state.loadWorkerLog() } }
            case .failed:
                Label("Failed", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Button("Try Again") { Task { await state.loadWorkerLog() } }
            }
        }
    }

    @ViewBuilder
    private func commentMetadata(_ comment: KanbanComment) -> some View {
        if let author = nonEmpty(comment.author) { Text(verbatim: author) }
        if let date = KanbanDetailDateFormatter.format(comment.createdAt) { Text(verbatim: date) }
    }

    private func eventSummary(_ event: KanbanDetailEvent) -> String {
        let details = [
            event.payload?.status,
            event.payload?.reason,
            event.payload?.summary,
            event.payload?.fields?.joined(separator: ", ")
        ].compactMap(nonEmpty)
        return ([event.kind].compactMap { $0 } + details).joined(separator: ": ")
    }

    private func runDateRange(_ run: KanbanDispatchRun) -> String? {
        let dates = [run.startedAt, run.finishedAt].compactMap(KanbanDetailDateFormatter.format)
        return dates.isEmpty ? nil : dates.joined(separator: " → ")
    }

    private func selectable(_ value: String?) -> some View {
        Text(verbatim: value ?? String(localized: "Unknown"))
            .textSelection(.enabled)
    }

    private func unavailable(title: LocalizedStringKey, detail: LocalizedStringKey, systemImage: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(detail)
        } actions: {
            if state.loadState == .failed {
                Button("Try Again") { Task { await state.refresh() } }
                    .frame(minHeight: 44)
            }
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

private enum KanbanDetailDateFormatter {
    static func format(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let date: Date?
        if let seconds = Double(value) {
            date = Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1_000 : seconds)
        } else {
            date = iso8601.date(from: value)
        }
        guard let date else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private static let iso8601 = ISO8601DateFormatter()
}

private enum KanbanDurationFormatter {
    static func full(_ seconds: Int) -> String {
        formatter.string(from: TimeInterval(max(0, seconds))) ?? String(localized: "Unknown")
    }

    private static let formatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        formatter.unitsStyle = .full
        return formatter
    }()
}
