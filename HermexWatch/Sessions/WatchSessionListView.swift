import SwiftUI
import HermexWatchRoot
import WatchShared

private struct CreatedSession: Hashable, Identifiable {
    let key: SessionKey
    /// Full scope, not just the server: the same session ID can reappear under a
    /// later generation of the same server.
    var id: String {
        let scope = key.scope
        return [
            scope.epoch.rawValue.uuidString,
            scope.server.rawValue.uuidString,
            String(scope.generation.rawValue),
            key.sessionID,
        ].joined(separator: ":")
    }
}

struct WatchSessionListView: View {
    @Bindable var model: WatchRootModel
    @State private var isCreating = false
    @State private var createdSession: CreatedSession?

    var body: some View {
        List {
            Button {
                Task { await createSession() }
            } label: {
                if isCreating {
                    HStack {
                        ProgressView()
                        Text("New session")
                    }
                } else {
                    Label("New session", systemImage: "plus")
                }
            }
            .accessibilityIdentifier("createSession")
            .disabled(isCreating || !model.canMutate)

            if let error = model.sidebarErrorCopy {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .listRowBackground(Color.clear)
            }
            if !model.hasLoadedSessions, model.sessions.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .listRowBackground(Color.clear)
            } else if model.sessions.isEmpty, model.lastErrorCode != "sessionsUnavailable" {
                VStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("No sessions yet")
                        .font(.footnote)
                    Text("Tap + to start one.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
                .accessibilityElement(children: .combine)
            }
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.sessions, id: \.key) { session in
                        NavigationLink {
                            WatchSessionDetailView(model: model, session: session)
                        } label: {
                            sessionRow(session)
                        }
                    }
                }
            }
        }
        .navigationTitle("Sessions")
        .navigationDestination(item: $createdSession) { created in
            if let session = model.session(for: created.key) {
                WatchSessionDetailView(model: model, session: session)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await createSession() }
                } label: {
                    if isCreating {
                        ProgressView()
                    } else {
                        Image(systemName: "plus")
                    }
                }
                .accessibilityLabel("New session")
                .accessibilityIdentifier("createSessionToolbar")
                .disabled(isCreating || !model.canMutate)
            }
        }
        .refreshable {
            await model.refreshFromList()
            WatchWidgetSnapshotPublisher.publish(model)
        }
    }

    /// Live work first so "what needs me" is the first thing under the wrist,
    /// then pinned, then everything else in server order.
    private var groups: [(title: String, sessions: [WatchSessionSummary])] {
        var active: [WatchSessionSummary] = []
        var pinned: [WatchSessionSummary] = []
        var recent: [WatchSessionSummary] = []
        for session in model.sessions {
            if WatchNowSession.isRunning(session.runState) || WatchNowSession.needsAttention(session) {
                active.append(session)
            } else if session.isPinned {
                pinned.append(session)
            } else {
                recent.append(session)
            }
        }
        return [("Active", active), ("Pinned", pinned), ("Recent", recent)]
            .filter { !$0.1.isEmpty }
            .map { (title: $0.0, sessions: $0.1) }
    }

    private func sessionRow(_ session: WatchSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(session.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if session.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Pinned")
                }
            }
            HStack(spacing: 4) {
                if let status = status(for: session) {
                    Circle()
                        .fill(status.tint)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(status.text)
                        .foregroundStyle(status.tint)
                } else if let updatedAt = session.updatedAt {
                    Text(updatedAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption2)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func status(for session: WatchSessionSummary) -> (text: String, tint: Color)? {
        if WatchNowSession.isRunning(session.runState) { return ("Running", .orange) }
        if WatchNowSession.needsAttention(session) { return ("Needs you", .yellow) }
        return nil
    }

    private func createSession() async {
        isCreating = true
        defer { isCreating = false }
        guard let key = await model.createSession() else {
            WatchHaptics.play(.failure)
            return
        }
        WatchHaptics.play(.success)
        WatchWidgetSnapshotPublisher.publish(model)
        createdSession = CreatedSession(key: key)
    }
}
