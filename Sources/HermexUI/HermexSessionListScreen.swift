import SwiftUI
import HermexCore

public struct HermexSessionListScreen: View {
    private let state: HermexSessionListState
    private let onEvent: (HermexUIEvent) -> Void

    public init(state: HermexSessionListState, onEvent: @escaping (HermexUIEvent) -> Void = { _ in }) {
        self.state = state
        self.onEvent = onEvent
    }

    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            HermexUIColors.systemBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header

                    HStack(alignment: .top, spacing: 20) {
                        utilityRail

                        VStack(alignment: .leading, spacing: 12) {
                            selectorRow(
                                icon: "person.crop.circle.badge.gearshape",
                                title: state.activeProfileName ?? "default",
                                subtitle: "Profile",
                                event: .selectProfile
                            )
                            selectorRow(
                                icon: "folder",
                                title: primaryWorkspace,
                                subtitle: "Workspace",
                                event: .selectWorkspace
                            )

                            if !state.searchQuery.isEmpty || state.isShowingArchived || state.isViewingCachedData {
                                statusRows
                            }

                            LazyVStack(spacing: 0) {
                                ForEach(state.sessions) { session in
                                    sessionRow(session)
                                        .hermexContentShapeRectangle()
                                        .onTapGesture {
                                            onEvent(.openSession(session.id))
                                        }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, HermexLayoutContract.sessionListHorizontalPadding)
                .padding(.top, HermexLayoutContract.sessionListTopPadding)
                .padding(.bottom, 112)
            }

            Button {
                onEvent(.newChat)
            } label: {
                Label("Chat", systemImage: "square.and.pencil")
                    .font(.headline.weight(.semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .background(Color.primary, in: Capsule())
                    .foregroundStyle(HermexUIColors.systemBackground)
                    .shadow(
                        color: .black.opacity(HermexLayoutContract.sessionListFloatingButtonShadowOpacity),
                        radius: HermexLayoutContract.sessionListFloatingButtonShadowRadius,
                        y: HermexLayoutContract.sessionListFloatingButtonShadowYOffset
                    )
            }
            .padding(.trailing, HermexLayoutContract.sessionListFloatingButtonTrailing)
            .padding(.bottom, HermexLayoutContract.sessionListFloatingButtonBottom)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            HermexLogoMark()
            Spacer(minLength: 12)
            HermexIconCluster {
                HermexCircleIconButton(
                    systemImage: "magnifyingglass",
                    accessibilityLabel: "Search sessions",
                    action: { onEvent(.searchSessions(state.searchQuery)) }
                )
                HermexCircleIconButton(
                    systemImage: "gearshape.fill",
                    accessibilityLabel: "Settings",
                    isFilled: true,
                    action: { onEvent(.openRoute(.settings)) }
                )
            }
        }
    }

    @ViewBuilder
    private var statusRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.isShowingArchived {
                Text("Archived sessions")
                    .foregroundStyle(.secondary)
            }
            if state.isViewingCachedData {
                Text("Cached data")
                    .foregroundStyle(.secondary)
            }
            if !state.searchQuery.isEmpty {
                Text("Searching \"\(state.searchQuery)\"")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.vertical, 4)
    }

    private var utilityRail: some View {
        VStack(spacing: 24) {
            railButton("calendar.badge.clock", "Tasks", .selectPanel(.tasks))
            railButton("hammer", "Skills", .selectPanel(.skills))
            railButton("brain.head.profile", "Memory", .selectPanel(.memory))
            railButton("chart.bar", "Insights", .selectPanel(.insights))
        }
        .frame(width: HermexLayoutContract.sessionListUtilityRailWidth)
    }

    private func railButton(_ systemImage: String, _ label: String, _ event: HermexUIEvent) -> some View {
        Button {
            onEvent(event)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 23, weight: .semibold))
                .frame(
                    width: HermexLayoutContract.sessionListUtilityIconSize,
                    height: HermexLayoutContract.sessionListUtilityIconSize
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func selectorRow(icon: String, title: String, subtitle: String, event: HermexUIEvent) -> some View {
        Button {
            onEvent(event)
        } label: {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .semibold))
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: HermexLayoutContract.sessionListSelectorHeight)
            .hermexContentShapeRectangle()
        }
        .buttonStyle(.plain)
    }

    private func sessionRow(_ session: HermexSessionDTO) -> some View {
        let metadata = sessionMetadata(session)
        let hasSupplemental = !metadata.isEmpty

        return HStack(alignment: .center, spacing: HermexLayoutContract.sessionRowHorizontalSpacing) {
            VStack(alignment: .leading, spacing: HermexLayoutContract.sessionRowContentSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: HermexLayoutContract.sessionRowTitleDateSpacing) {
                    HStack(alignment: .firstTextBaseline, spacing: HermexLayoutContract.sessionRowTitlePinSpacing) {
                        Text(session.title ?? "Untitled Session")
                            .font(.headline.weight(.semibold))
                            .lineLimit(2)
                            .truncationMode(.tail)

                        if session.pinned == true {
                            Image(systemName: "pin.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .layoutPriority(2)

                    Spacer(minLength: HermexLayoutContract.sessionRowTitleDateSpacing)

                    if let relativeDate = relativeDate(session) {
                        Text(relativeDate)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if hasSupplemental {
                    HStack(alignment: .firstTextBaseline, spacing: HermexLayoutContract.sessionRowMetadataSpacing) {
                        Text(metadata)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                onEvent(.selectProject(session.projectId))
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline.weight(.semibold))
                    .frame(
                        width: HermexLayoutContract.sessionListRowActionSize,
                        height: HermexLayoutContract.sessionListRowActionSize
                    )
                    .background(HermexUIColors.secondarySystemBackground.opacity(0.72), in: Circle())
                    .overlay {
                        Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.6)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Session actions")
        }
        .padding(.horizontal, HermexLayoutContract.sessionRowHorizontalPadding)
        .padding(.vertical, HermexLayoutContract.sessionRowVerticalPadding)
        .frame(
            minHeight: hasSupplemental
                ? HermexLayoutContract.sessionRowSupplementalMinimumHeight
                : HermexLayoutContract.sessionRowMinimumHeight,
            alignment: .center
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(HermexLayoutContract.sessionListRowSeparatorOpacity))
                .frame(height: 0.6)
        }
        .hermexContentShapeRectangle()
    }

    private func sessionMetadata(_ session: HermexSessionDTO) -> String {
        let count = session.messageCount.map { "\($0) messages" }
        return [count, session.workspace].compactMap { $0 }.joined(separator: " * ")
    }

    private var primaryWorkspace: String {
        state.sessions.first(where: { $0.workspace?.isEmpty == false })?.workspace ?? "workspace"
    }

    private func relativeDate(_ session: HermexSessionDTO) -> String? {
        guard let timestamp = session.lastMessageAt ?? session.updatedAt ?? session.createdAt else { return nil }
        let seconds = max(0, Date().timeIntervalSince1970 - timestamp)
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }
}
