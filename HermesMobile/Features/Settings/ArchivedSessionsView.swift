import SwiftUI

/// A server's archived sessions, with Unarchive (#17). On a Hermes server (#1048) they are one
/// Profile's, hidden Bot Chats included, paged 100 at a time, with Delete as well. A Bot Chat row
/// opens in its bot on the Bots tab (#1146).
struct ArchivedSessionsView: View {
    let server: URL
    /// Forwarded to `ChatView` and used for load/unarchive failures so a 401
    /// here triggers the same re-login flow as everywhere else.
    let onAPIError: (Error) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: ArchivedSessionsViewModel
    @State private var openedSession: SessionSummary?
    /// The Hermes session a row opened.
    @State private var openedHermesChat: HermesSessionChat?
    @State private var sessionPendingDeletion: SessionSummary?
    @AppStorage(SessionRowDisplaySettings.showMessageCountKey) private var showsSessionMessageCount = true
    @AppStorage(SessionRowDisplaySettings.showWorkspaceKey) private var showsSessionWorkspace = true
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true

    init(server: URL, onAPIError: @escaping (Error) -> Void) {
        self.server = server
        self.onAPIError = onAPIError
        _viewModel = State(initialValue: ArchivedSessionsViewModel(server: server))
    }

    /// A Hermes server's Archived screen (#1048), from its Sessions list or Settings.
    init(server: URL, hermes: HermesArchiveSource) {
        self.server = server
        onAPIError = { _ in }
        _viewModel = State(initialValue: ArchivedSessionsViewModel(server: server, hermes: hermes))
    }

    var body: some View {
        content
            .adaptiveReadableScrollContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            .navigationTitle("Archived Sessions")
            .navigationDestination(item: $openedSession) { session in
                // Opening an archived session reuses the normal read path —
                // no special-casing on the chat side (issue #17).
                ChatView(session: session, server: server, onAPIError: onAPIError)
            }
            .navigationDestination(item: $openedHermesChat) { chat in
                ChatView(hermesSession: chat).id(chat.id)
            }
            .task {
                await load()
            }
            .refreshable {
                await load()
            }
            .onDisappear {
                // A pushed chat keeps the screen's client; leaving for good ends it.
                if viewModel.isHermes, openedHermesChat == nil { viewModel.close() }
            }
            .onChange(of: scenePhase) {
                // The background closes a Hermes server's socket; the screen reads again on return.
                guard viewModel.isHermes else { return }
                switch scenePhase {
                case .background: viewModel.close()
                case .active where openedHermesChat == nil && !viewModel.isConnected: Task { await load() }
                default: break
                }
            }
            .onChange(of: openedHermesChat == nil) { _, closed in
                // Back from a chat the background closed this screen's client under.
                if closed, viewModel.isHermes, !viewModel.isConnected { Task { await load() } }
            }
            .alert(
                "Delete Session?",
                isPresented: Binding(
                    get: { sessionPendingDeletion != nil },
                    set: { if !$0 { sessionPendingDeletion = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) { sessionPendingDeletion = nil }
                Button("Delete", role: .destructive) {
                    if let session = sessionPendingDeletion { delete(session) }
                    sessionPendingDeletion = nil
                }
            } message: {
                Text("This deletes the session and its messages from the Hermes host. It can't be undone.")
            }
            .alert(
                "Action Failed",
                isPresented: Binding(
                    get: { viewModel.actionErrorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            viewModel.clearActionError()
                        }
                    }
                )
            ) {
                Button("OK") {
                    viewModel.clearActionError()
                }
            } message: {
                Text(viewModel.actionErrorMessage ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if viewModel.isLoading && viewModel.sessions.isEmpty {
                    ArchivedStatusRow(title: String(localized: "Loading archived sessions..."), systemImage: "archivebox")
                        .padding(.horizontal, 24)
                } else if let errorMessage = viewModel.errorMessage, viewModel.sessions.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ArchivedStatusRow(title: String(localized: "Could not load archived sessions"), systemImage: "exclamationmark.triangle")

                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)

                        Button("Try Again") {
                            Task { await load() }
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 24)
                } else if viewModel.sessions.isEmpty && !viewModel.hasMore {
                    ArchivedStatusRow(title: String(localized: "No archived sessions"), systemImage: "archivebox")
                        .padding(.horizontal, 24)
                } else {
                    VStack(spacing: 2) {
                        ForEach(visibleSessions) { session in
                            archivedSessionRow(for: session)
                        }
                    }
                    .padding(.horizontal, 12)

                    if viewModel.hasMore { loadMoreRow }
                }
            }
            .padding(.top, 28)
            .padding(.bottom, 44)
        }
    }

    /// The end of a Hermes server's archived rows: the next page loads as it comes into view,
    /// and a tap tries again after a failed one.
    private var loadMoreRow: some View {
        Button("Load more") { Task { await viewModel.loadMore() } }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .disabled(viewModel.isLoadingMore)
            .frame(maxWidth: .infinity, minHeight: 44)
            .onAppear { Task { await viewModel.loadMore() } }
    }

    private func archivedSessionRow(for session: SessionSummary) -> some View {
        HStack(spacing: 0) {
            Button {
                if let bot = viewModel.hermesBot(for: session) {
                    AppIntentRouter.shared.requestDeepLink(HermesDeepLink.botURL(for: bot))
                } else if viewModel.isHermes {
                    openedHermesChat = viewModel.hermesChat(for: session)
                } else {
                    openedSession = session
                }
            } label: {
                SessionRowView(
                    session: session,
                    showsMessageCount: showsSessionMessageCount,
                    showsWorkspace: showsSessionWorkspace
                )
            }
            .buttonStyle(.plain)

            unarchiveButton(for: session)
        }
        .contextMenu {
            Button {
                unarchive(session)
            } label: {
                Label("Unarchive", systemImage: "arrow.up.bin")
            }
            .disabled(viewModel.isChanging(session))

            if viewModel.isHermes {
                Button(role: .destructive) {
                    sessionPendingDeletion = session
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(viewModel.isChanging(session))
            }
        }
    }

    /// Always-visible unarchive affordance; the context menu keeps the same
    /// action for discoverability parity with the main list's row menus.
    private func unarchiveButton(for session: SessionSummary) -> some View {
        Button {
            unarchive(session)
        } label: {
            Group {
                if viewModel.isUnarchiving(session) {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.up.bin")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isChanging(session))
        .accessibilityLabel("Unarchive")
    }

    private func unarchive(_ session: SessionSummary) {
        Task {
            let didUnarchive = await viewModel.unarchive(session)
            handleLastError()
            if didUnarchive {
                SessionHaptics.archiveStateChanged(isEnabled: isHapticsEnabled)
            }
        }
    }

    private func delete(_ session: SessionSummary) {
        Task {
            if await viewModel.delete(session, modelContext: modelContext) {
                SessionHaptics.sessionDeleted(isEnabled: isHapticsEnabled)
            }
        }
    }

    private func load() async {
        await viewModel.load()
        handleLastError()
    }

    private func handleLastError() {
        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }

    private var visibleSessions: [SessionSummary] {
        viewModel.sessions.sorted { left, right in
            if (left.pinned == true) != (right.pinned == true) {
                return left.pinned == true
            }

            return timestamp(for: left) > timestamp(for: right)
        }
    }

    private func timestamp(for session: SessionSummary) -> Double {
        session.lastMessageAt ?? session.updatedAt ?? session.createdAt ?? 0
    }
}

private struct ArchivedStatusRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)

            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .frame(minHeight: 42)
    }
}
