import SwiftUI
import HermexWatchRoot
import WatchShared

struct WatchNowView: View {
    @Bindable var model: WatchRootModel
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @State private var isCreating = false

    var body: some View {
        // A free-standing stack draws under the large title on watchOS, so the
        // server name painted through "Now". A List is inset below that title.
        // navigationSubtitle is unavailable on watchOS, so the hostname is a
        // caption row with middle truncation.
        List {
            serverCaption
            if let note = model.phoneStatusNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !model.hasLoadedSessions, model.nowSession == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .listRowBackground(Color.clear)
            } else if let session = model.nowSession {
                NavigationLink {
                    WatchSessionDetailView(model: model, session: session)
                } label: {
                    sessionCard(session)
                }
                .accessibilityIdentifier("openChat")
                .accessibilityHint("Opens the conversation.")

                if let error = model.sidebarErrorCopy {
                    errorRow(error)
                }
                // Hides its own controls in Always-On but stays mounted, so a
                // reply being read aloud keeps playing with the wrist down.
                WatchSpeakControls(
                    model: model,
                    session: session,
                    listenText: model.nowSpokenReply
                )
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            } else if model.lastErrorCode == "sessionsUnavailable", let error = model.sidebarErrorCopy {
                errorRow(error)
            } else {
                emptyState
            }
            if !isLuminanceReduced {
                navigationSections
            }
        }
        .navigationTitle("Now")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                WatchHermesLogo()
                    .frame(width: 108, height: 31, alignment: .leading)
                    .accessibilityLabel("Hermex")
            }
        }
        .onChange(of: model.complicationRecordID) { _, _ in
            model.discardUnusableComplicationRecording()
        }
        .onChange(of: model.hasLoadedSessions) { _, _ in
            model.discardUnusableComplicationRecording()
        }
        .refreshable {
            await model.refreshFromList()
            WatchWidgetSnapshotPublisher.publish(model)
        }
    }

    private func sessionCard(_ session: WatchSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor(for: session))
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(statusLabel(for: session))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor(for: session))
            }
            Text(session.title)
                .font(.headline)
                .lineLimit(2)
            if let preview = model.nowPreview {
                Text(verbatim: WatchTextBreaking.breakable(preview))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        Group {
            VStack(alignment: .leading, spacing: 2) {
                Text("No session")
                    .font(.headline)
                Text("Start one here, or open Sessions.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowBackground(Color.clear)
            if let error = model.sidebarErrorCopy {
                errorRow(error)
            }
            Button {
                Task { await createSession() }
            } label: {
                if isCreating {
                    ProgressView()
                } else {
                    Label("New session", systemImage: "plus")
                }
            }
            .disabled(isCreating || !model.canMutate)
        }
    }

    private func errorRow(_ error: String) -> some View {
        Label(error, systemImage: "exclamationmark.circle")
            .font(.caption2)
            .foregroundStyle(.red)
            .listRowBackground(Color.clear)
    }

    /// Ordered by how often a wrist needs them: conversations, then live state
    /// (tasks, board, spend), then reference (profile, skills, memory, projects).
    @ViewBuilder
    private var navigationSections: some View {
        Section {
            NavigationLink {
                WatchSessionListView(model: model)
            } label: {
                WatchNavRow(
                    title: "Sessions",
                    assetImage: nil,
                    systemImage: "bubble.left.and.bubble.right",
                    detail: sessionsDetail,
                    detailTint: attentionCount > 0 ? .yellow : .secondary
                )
            }
            .accessibilityIdentifier("nav.sessions")
        }
        Section("Glance") {
            NavigationLink {
                WatchTaskListView(model: model)
            } label: {
                WatchNavRow(title: "Tasks", assetImage: "LucideCalendarClock")
            }
            NavigationLink {
                WatchKanbanListView(model: model)
            } label: {
                WatchNavRow(title: "Kanban", assetImage: "LucideColumns3")
            }
            NavigationLink {
                WatchUsageListView(model: model)
            } label: {
                WatchNavRow(title: "Usage", assetImage: "LucideChartColumnIncreasing")
            }
        }
        Section("Agent") {
            NavigationLink {
                WatchProfileListView(model: model)
            } label: {
                WatchNavRow(title: "Profile", assetImage: "LucideUserRoundCog")
            }
            NavigationLink {
                WatchSkillListView(model: model)
            } label: {
                WatchNavRow(title: "Skills", assetImage: "LucideHammer")
            }
            NavigationLink {
                WatchMemoryListView(model: model)
            } label: {
                WatchNavRow(title: "Memory", assetImage: "LucideBrain")
            }
            NavigationLink {
                WatchProjectListView(model: model)
            } label: {
                WatchNavRow(title: "Projects", assetImage: "LucideFolder")
            }
        }
    }

    private var attentionCount: Int {
        model.sessions.filter(WatchNowSession.needsAttention).count
    }

    /// Attention wins over the plain count: "2 need you" is the wrist question.
    private var sessionsDetail: String? {
        if attentionCount == 1 { return "1 needs you" }
        if attentionCount > 1 { return "\(attentionCount) need you" }
        return model.sessions.isEmpty ? nil : "\(model.sessions.count)"
    }

    private var serverCaption: some View {
        Text(model.primaryMessage)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Server, \(model.primaryMessage)")
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 2, trailing: 8))
    }

    private func statusLabel(for session: WatchSessionSummary) -> String {
        if WatchNowSession.isRunning(session.runState) { return "Running" }
        if WatchNowSession.needsAttention(session) { return "Needs you" }
        if session.isPinned { return "Pinned" }
        return "Ready"
    }

    private func statusColor(for session: WatchSessionSummary) -> Color {
        if WatchNowSession.isRunning(session.runState) { return .orange }
        if WatchNowSession.needsAttention(session) { return .yellow }
        return .green
    }

    private func createSession() async {
        isCreating = true
        defer { isCreating = false }
        if await model.createSession() != nil {
            WatchHaptics.play(.success)
            WatchWidgetSnapshotPublisher.publish(model)
        } else {
            WatchHaptics.play(.failure)
        }
    }
}

/// The iPhone header wordmark: a gold fill, shading, highlight, and outline.
/// Width stays near 108pt so it sits in the top-left without crowding the title.
private struct WatchHermesLogo: View {
    private static let aspectRatio = 643.0 / 185.0
    /// The iPhone default header color, `#FFD700`.
    private static let gold = Color(red: 1, green: 0.843, blue: 0)

    var body: some View {
        ZStack {
            Image("hermes-fill-mask")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(Self.gold)

            Image("hermes-shading-overlay")
                .resizable()
                .scaledToFit()
                .blendMode(.multiply)

            Image("hermes-highlight")
                .resizable()
                .scaledToFit()
                .blendMode(.screen)

            Image("hermes-outline-shadow")
                .resizable()
                .scaledToFit()
        }
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
        .compositingGroup()
    }
}
