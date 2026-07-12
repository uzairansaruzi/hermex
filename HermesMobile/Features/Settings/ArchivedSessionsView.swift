import SwiftUI

struct ArchivedSessionsView: View {
    let server: URL
    /// Forwarded to `ChatView` and used for load/unarchive failures so a 401
    /// here triggers the same re-login flow as everywhere else.
    let onAPIError: (Error) -> Void

    @State private var viewModel: ArchivedSessionsViewModel
    @State private var openedSession: SessionSummary?
    @AppStorage(SessionRowDisplaySettings.showMessageCountKey) private var showsSessionMessageCount = true
    @AppStorage(SessionRowDisplaySettings.showWorkspaceKey) private var showsSessionWorkspace = true
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true

    init(server: URL, onAPIError: @escaping (Error) -> Void) {
        self.server = server
        self.onAPIError = onAPIError
        _viewModel = State(initialValue: ArchivedSessionsViewModel(server: server))
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
            .task {
                await load()
            }
            .refreshable {
                await load()
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
                } else if viewModel.sessions.isEmpty {
                    ArchivedStatusRow(title: String(localized: "No archived sessions"), systemImage: "archivebox")
                        .padding(.horizontal, 24)
                } else {
                    VStack(spacing: 2) {
                        ForEach(visibleSessions) { session in
                            archivedSessionRow(for: session)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            .padding(.top, 28)
            .padding(.bottom, 44)
        }
    }

    private func archivedSessionRow(for session: SessionSummary) -> some View {
        HStack(spacing: 0) {
            Button {
                openedSession = session
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
            .disabled(viewModel.isUnarchiving(session))
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
        .disabled(viewModel.isUnarchiving(session))
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
